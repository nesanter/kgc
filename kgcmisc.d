module gc.misc;

//debug = USAGE;
debug = STATS;

import clib = core.stdc.stdlib;
import gc.gc : onOutOfMemoryError;
import gc.proxy;
import gc.t_main;
import core.sys.posix.signal;
import core.atomic;
version (unittest) import core.stdc.stdio : printf;
else debug (USAGE) import core.stdc.stdio : printf;

struct BlkInfo
{
    void*  base;
    size_t size;
    uint   attr;
}


/* Most of the time this will just crash the program
 * (especially when called in a GCT)
 * 
 * Specifiy msg=true in onGCFatalError to print something vaguely useful
 */ 

class GCError : Error {
    this() {
        super("Fatal GC Error");
    }
}

void onGCFatalError(bool msg=true, int l=__LINE__) {
    if (msg) printf("<GC> fatal error (line %d)! Aborting!\n",l);
    clib.abort();
}

class GCAssertError : Error {
    this() {
        super("GC Assertion Error");
    }
}

void onGCAssertError(bool msg=true) {
    if (msg) printf("<GC> assertion error!\n");
    clib.abort();
}

void gcAssert(bool b) {
    version (assert) {
        if (!b)
            onGCAssertError();
    } else version (unittest) {
        if (!b)
            onGCAssertError();
    } else {
        pragma(msg, "gcAssert() disabled");
    }
}

struct Range {
    void* pbot, ptop;
}

void* getStackTop() {
    asm { naked; mov RAX, RSP; ret; }
}

size_t getRangesSize() {
    size_t sz = 0;
    for (int i=0; i<_gc.nranges; ++i)
        sz += _gc.ranges[i].ptop - _gc.ranges[i].pbot;
    return sz;
}

alias PointerQueueT!false PointerQueue;
alias PointerQueueT!true RootSet;

struct PointerQueueT(bool isRootSet) {
    static if (isRootSet) {
        struct PNode {
            void* ptr;
            PNode* next;
            void** sptr;
        }
    } else {
        struct PNode {
            void* ptr;
            PNode* next;
        }
    }
    
    PNode* root;
    //used for miscRootsQueue
    bool dirty, empty;
    PNode* copyTail, copyRoot;
    
    debug (STATS) {
        ptrdiff_t netAllocs;
        size_t maxLength;
        size_t length;
    }
    
    void initialize() {
        root = null;
        empty = false;
        copyTail = null;
        copyRoot = null;
    }
    
    static if (isRootSet) {
        void enqueue(void* p, void** b) {
            debug (USAGE) printf("<GC> PointerQueueT.enqueue (%p)\n",p);
            debug (STATS) {
                length++;
                netAllocs++;
                if (length > maxLength)
                    maxLength = length;
            }
            if (root is null) {
                root = cast(PNode*)clib.malloc(PNode.sizeof);
                if (root is null)
                    onOutOfMemoryError();
                *root = PNode(p, null, b);
                return;
            }
            PNode* pn;
            pn = cast(PNode*)clib.malloc(PNode.sizeof);
            if (pn is null)
                onOutOfMemoryError();
            *(pn) = PNode(p, root, b);
            root = pn;
        }
    } else {
        void enqueue(void* p) {
            debug (USAGE) printf("<GC> PointerQueueT.enqueue (%p)\n",p);
            debug (STATS) {
                length++;
                netAllocs++;
                if (length > maxLength)
                    maxLength = length;
            }
            if (root is null) {
                root = cast(PNode*)clib.malloc(PNode.sizeof);
                if (root is null)
                    onOutOfMemoryError();
                *root = PNode(p, null);
                return;
            }
            PNode* pn;
            pn = cast(PNode*)clib.malloc(PNode.sizeof);
            if (pn is null)
                onOutOfMemoryError();
            *(pn) = PNode(p, root);
            root = pn;
        }
    }
    
    //I don't think this is/should be used
    void dequeue(void** buffer) {
        debug (USAGE) printf("<GC> PointerQueueT.dequeue (%p)\n",buffer);
        //void** ptrs = cast(void**)clib.malloc(length * (void*).sizeof);
        PNode* pn = root, pnnext;
        size_t i;
        while (pn != null) {
            buffer[i] = pn.ptr;
            pnnext = pn.next;
            clib.free(pn);
            pn = pnnext;
            i++;
        }
        root = null;
    }
    
    void freeNodes() {
        debug (USAGE) printf("<GC> PointerQueueT.freeNodes ()\n");
        debug (STATS) length = 0;
        PNode* pn = root, pnnext;
        while (pn != null) {
            pnnext = pn.next;
            clib.free(pn);
            pn = pnnext;
        }
    }
    
    void remove(void* p) {
        debug (USAGE) printf("<GC> PointerQueueT.remove ()\n");
        PNode* pn = root;
        PNode** pnslot = &root;
        while (pn != null) {
            if (pn.ptr == p) {
                *pnslot = pn.next;
                clib.free(pn);
                dirty = true;
                debug (STATS)
                    length--;
                return;
            }
            pnslot = &pn.next;
            pn = pn.next;
        }
    }
    
    int iter(bool realTail)(int delegate(ref void*) dg) {
        int result = 0;
        PNode* pn = root;
        while (pn !is null && !realTail && pn != copyTail) {
            result = dg(pn.ptr);
            if (result) break;
            pn = pn.next;
        }
        return result;
    }
    
    void iterDequeue(void delegate(void*) dg) {
        PNode* pn = root, pnnext;
        size_t i;
        while (pn != null) {
            dg(pn.ptr);
            pnnext = pn.next;
            clib.free(pn);
            pn = pnnext;
            i++;
        }
        root = null;
    }
        
    void release(size_t* release_size) {
        debug (USAGE) printf("<GC> PointerQueueT.release (%p)\n",release_size);
        size_t released = 0;
        PNode* pn = root, pnnext;
        while (pn !is null) {
            _gc.primaryFL.releaseRegion(pn.ptr, release_size);
            pnnext = pn.next;
            clib.free(pn);
            pn = pnnext;
        }
        root = null;
    }
        
    /*  This is called by the sweeper to make a copy of the miscRootQueue
     *    + The variable "copyTail" on the destination queue
     *      controls where the dests scan will stop
     *    + The variable "copyRoot" on the source queue controls
     *      the depth the last copy reached
     *    + The dirty flag on the source queue controls
     *      whether or not we need to copy over the whole queue again
     *      because something got removed
     *  Under this system, PNodes are never freed from the copied queue
     *  they are simply kept to be reused if a root is added
     *  This should work well because there should be either a few roots
     *  or a fairly stable number of roots.
     */
    void copy(PointerQueueT!isRootSet* destination) {
        debug (USAGE) printf("<GC> PointerQueueT.copy (%p)\n",destination);
        debug (STATS) {
            size_t used = 0;
            if (length > destination.length) {
                destination.length = length;
                destination.maxLength = length;
            }
        }
        if (root == null) {
            printf("source queue is empty\n");
            destination.copyTail = null;
            destination.empty = true; //to distinguish between tail-at-end
                                      //and tail-at-beginning
            return;
        }
        if (dirty || destination.root is null) { //need to copy the whole queue
            printf("copying whole queue\n");
            PNode* pn = root, newpn;
            PNode** pnslot = &destination.root;
            while (pn !is null) {
                if (*pnslot is null) {
                    debug (STATS) used++;
                    newpn = cast(PNode*)clib.malloc(PNode.sizeof);
                    newpn.ptr = pn.ptr;
                    newpn.next = *pnslot;
                    *pnslot = newpn;
                    pnslot = &newpn.next;
                } else {
                    debug (STATS) used--;
                    (*pnslot).ptr = pn.ptr;
                    pnslot = &(*pnslot).next;
                }
                pn = pn.next;
            }
            destination.copyTail = *pnslot;
            copyRoot = root;
        } else if (copyRoot != root) { //appendings have happened
            printf("appending\n");
            PNode* pn = copyRoot, newpn;
            PNode** pnslot = &destination.copyTail;
            while (pn !is null) {
                if (*pnslot is null) {
                    debug (STATS) used++;
                    newpn = cast(PNode*)clib.malloc(PNode.sizeof);
                    newpn.ptr = pn.ptr;
                    newpn.next = *pnslot;
                    *pnslot = newpn;
                    pnslot = &newpn.next;
                } else {
                    debug (STATS) used--;
                    (*pnslot).ptr = pn.ptr;
                    pnslot = &(*pnslot).next;
                }
                pn = pn.next;
            }
            destination.copyTail = *pnslot;
            copyRoot = root;
        }
        debug (STATS) destination.netAllocs += used;
    }
    
    void print(bool tailed=false)(string name="(unnamed)\0") {
        static if (isRootSet)
            printf("+--Root Set--------\n");
        else
            printf("+--Pointer Queue---\n");
        printf("| Name: %s\n",name.ptr);
        if (root is null) {
            printf("| (empty queue)\n");
            debug (STATS) print_stats();
            else printf("+------------------\n");
            return;
        }
        bool pastTail = tailed && empty;
        PNode* pn = root;
        size_t i;
        while (pn !is null) {
            if (pn == copyTail)
                pastTail = true;
            if (pastTail)
                printf("| %lu - (empty slot)\n",i);
            else
                printf("| %lu - %p\n",i,pn.ptr);
            pn = pn.next;
            i++;
        }
        debug (STATS) print_stats();
        else printf("+------------------\n");
    }
    
    debug (STATS) {
        void print_stats() {
            printf("+--Statistics:-----\n");
            printf("| Max length: %lu\n",maxLength);
            printf("| Net use:    %ld\n",netAllocs);
            printf("+------------------\n");
        }
    }
}

unittest {
    printf("---PointerQueue unittest---\n");
    PointerQueue p, q;
    int a = 1, b = 2, c = 3, d = 4;
    p.initialize();
    q.initialize();
    p.enqueue(&a);
    p.enqueue(&b);
    p.enqueue(&c);
    //void** ptrs = cast(void**)clib.malloc(p.length * (void*).sizeof);
    //p.dequeue(ptrs);
    //p.print("p");
    void*[3] ptrs;
    int i=0;
    p.iter!false((ref ptr) {ptrs[i++] = ptr; return 0;});
    assert(ptrs[0] == &c);
    assert(ptrs[1] == &b);
    assert(ptrs[2] == &a);
    p.copy(&q);
    //q.print("q");
    i=0;
    q.iter!false((ref ptr) {ptrs[i++] = ptr; return 0;});
    assert(ptrs[0] == &c);
    assert(ptrs[1] == &b);
    assert(ptrs[2] == &a);
    p.remove(&b);
    //p.print("p");
    p.copy(&q);
    //q.print("q");
    i=0;
    q.iter!false((ref ptr) {ptrs[i++] = ptr; return 0;});
    assert(ptrs[0] == &c);
    assert(ptrs[1] == &a);
    p.enqueue(&d);
    //p.enqueue(&e);
    p.copy(&q);
    //q.print("q");
    i=0;
    q.iter!false((ref ptr) {ptrs[i++] = ptr; return 0;});
    //assert(ptrs[0] == &e);
    assert(ptrs[0] == &d);
    assert(ptrs[1] == &c);
    assert(ptrs[2] == &a);
    p.remove(&a);
    p.remove(&c);
    p.remove(&d);
    p.enqueue(&a);
    p.enqueue(&b);
    p.enqueue(&c);
    p.copy(&q);
    //q.print("q");
    i=0;
    q.iter!false((ref ptr) {ptrs[i++] = ptr; return 0;});
    //assert(ptrs[0] == &e);
    assert(ptrs[0] == &c);
    assert(ptrs[1] == &b);
    assert(ptrs[2] == &a);
    
    //clib.free(ptrs);
    printf("---end unittest---\n");
}

struct QStateMutex {
    enum State { ALPHA, BETA, GAMMA, DELTA }
    shared bool locked;
    shared State state;
    shared int waiters;
    void initialize() {
        state = State.ALPHA;
        locked = false;
    }
    
    private void _lock(bool wait=true, bool yield=true) {
        while (!cas(&locked, false, true)) {
            if (!wait) return;
            if (yield) .yield();
        }
    }
    private void _unlock() {
        locked = false;
    }
    
    bool wait(bool delegate() dg) {
        debug (USAGE) printf("<GC> QueueStateMutex.wait ()\n");
        _lock();
        waiters++;
        _unlock();
        
        while (state != State.ALPHA) {
            .yield();
        }
        bool result = dg();
        
        _lock();
        waiters--;
        _unlock();

        return result;
    }
    
    bool acquire() {
        debug (USAGE) printf("<GC> QStateMutex.acquire ()\n");
        bool result;
        while (true) {
            _lock();
            if (waiters == 0) {
                result = cas(&state, State.ALPHA, State.BETA);
                _unlock();
                return result;
            }
            _unlock();
            .yield();
        }
    }
    bool transfer() {
        debug (USAGE) printf("<GC> QStateMutex.transfer ()\n");
        return cas(&state, State.BETA, State.GAMMA);
    }
    bool acquire2() {
        debug (USAGE) printf("<GC> QStateMutex.acquire2 ()\n");
        return cas(&state, State.GAMMA, State.DELTA);
    }
    bool release() {
        debug (USAGE) printf("<GC> QStateMutex.release ()\n");
        return cas(&state, State.DELTA, State.ALPHA);
    }
    
    @property bool inactive() {
        return state == State.ALPHA;
    }
}

unittest {
    printf("---QStateMutex unittest---\n");
    QStateMutex m;
    m.acquire();
    gcAssert(!m.inactive);
    m.transfer();
    m.acquire2();
    m.release();
    gcAssert(m.inactive);
    printf("---end unittest---\n");
}
