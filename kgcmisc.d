module gc.misc;

debug = USAGE;

import clib = core.stdc.stdlib;
import gc.gc : onOutOfMemoryError;
import gc.proxy;
import gc.t_main;
import core.sys.posix.signal;
import core.atomic;
version (unittest) import core.stdc.stdio : printf;
else debug (USAGE) import core.stdc.stdio : printf;


version = GCASSERT;

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

/*
 *  This could be enhanced with a Freelist
 */
struct PointerQueue {
    struct PNode {
        void* ptr;
        PNode* next;
    }
    
    PNode* root;
    size_t length;
    //used for miscRootsQueue
    bool dirty;
    PNode* copyTail, copyRoot;
    
    void initialize() {
        root = null;
        length = 0;
    }
    
    void enqueue(void* p) {
        debug (USAGE) printf("<GC> PointerList.enqueue (%p)\n",p);
        if (root is null) {
            root = cast(PNode*)clib.malloc(PNode.sizeof);
            if (root is null)
                onOutOfMemoryError();
            *root = PNode(p, null);
            length++;
            return;
        }
        PNode* pn;
        pn = cast(PNode*)clib.malloc(PNode.sizeof);
        if (pn is null)
            onOutOfMemoryError();
        *(pn) = PNode(p, root);
        root = pn;
        length++;
    }
    
    //I don't think this is/should be used
    void dequeue(void** buffer) {
        debug (USAGE) printf("<GC> PointerList.dequeue (%p)\n",buffer);
        if (length == 0) return;
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
        length = 0;
    }
    
    void freeNodes() {
        debug (USAGE) printf("<GC> PointerList.freeNodes ()\n");
        PNode* pn = root, pnnext;
        while (pn != null) {
            pnnext = pn.next;
            clib.free(pn);
            pn = pnnext;
        }
    }
    
    void remove(void* p) {
        PNode* pn = root, pnprev;
        while (pn != null) {
            if (pn.ptr == p) {
                if (pnprev is null) {
                    root = pn.next;
                } else {
                    pnprev.next = pn.next;
                }
                clib.free(pn);
                dirty = true;
                return;
            }
        }
    }
    
    int iter(int delegate(ref void*) dg) {
        int result = 0;
        PNode* pn = root;
        while (pn !is null) {
            result = dg(pn.ptr);
            if (result) break;
        }
        return result;
    }
    
    void release(size_t* release_size) {
        debug (USAGE) printf("<GC> PointerList.release (%p)\n",release_size);
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
        
    void copy(PointerQueue* destination) {
        /*
        if (root == null) {
            destination.copyTail = null;
            return;
        }
        if (dirty || copyRoot is null) { //removals have happened
            PNode* pn = root, pndest = destination.root, newpn, pnprev;
            while (pn !is null) {
                if (pndest is null) {
                    newpn = cast(PNode*)clib.malloc(PNode.sizeof);
                    *newpn = PNode(pn.ptr, null);
                    pnprev.next = newpn;
                } else {
                    pndest.ptr = pn.ptr;
                    pndest = pndest.next;
                }
                pnprev = pn;
                pn = pn.next;
            }
            destination.copyTail = pndest is null ? newpn : pndest;
            copyRoot = root;
            return;
        } else if (copyRoot != root) { //appendings have happened
            PNode* pn = copyRoot, pndest = destination.copyTail, newpn;
            while (pn !is null) {
                if (destination.copyTail is null || destination.copyTail.next is null) {
                    newpn = cast(PNode*)clib.malloc(PNode.sizeof);
                    *newpn = PNode(pn.ptr, destination.root);
                }
                
                destination.root = newpn;
                pn = pn.next;
            }
            copy
        }
        */
    }
    
}

unittest {
    printf("---PointerQueue unittest---\n");
    PointerQueue p;
    int a = 1, b = 2, c = 3;
    p.initialize();
    p.enqueue(&a);
    p.enqueue(&b);
    p.enqueue(&c);
    assert(p.length == 3);
    void** ptrs = cast(void**)clib.malloc(p.length * (void*).sizeof);
    p.dequeue(ptrs);
    assert(ptrs[0] == &c);
    assert(ptrs[1] == &b);
    assert(ptrs[2] == &a);
    clib.free(ptrs);
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
        return cas(&state, State.BETA, State.GAMMA);
    }
    bool acquire2() {
        return cas(&state, State.GAMMA, State.DELTA);
    }
    bool release() {
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
