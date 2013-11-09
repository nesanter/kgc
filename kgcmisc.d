module gc.misc;

debug = USAGE;

import clib = core.stdc.stdlib;
import gc.gc : onOutOfMemoryError, _gcerror, _gcasserterror;
import gc.proxy;
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

void onGCFatalError(bool msg=false) {
    if (msg) printf("<GC> fatal error!\n");
    throw _gcerror;
}

class GCAssertError : Error {
    this() {
        super("GC Assertion Error");
    }
}

void onGCAssertError(bool msg=false) {
    if (msg) printf("<GC> assertion error!\n");
    throw _gcasserterror;
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

struct PointerQueue {
    struct PNode {
        void* ptr;
        PNode* next;
    }
    
    PNode* root;
    size_t length;
    
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
    
    void dequeue(void** buffer) {
        debug (USAGE) printf("<GC> PointerList.dequeue ()\n");
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
