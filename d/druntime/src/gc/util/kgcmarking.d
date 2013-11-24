/* 
 *  Marking routines
 */

module gc.util.marking;

//debug = USAGE;
//debug = GC_PROFILE;

import gc.util.freelists;
import gc.proxy;
import gc.util.misc;
import gc.util.injector;
static import gc.util.grapher;
import clib = core.stdc.stdlib;

debug (GC_PROFILE) import core.stdc.time;

//Scan a region for pointers
void scanForPointers(void* ptr, size_t sz, PointerQueue* q) {
    printf("<M> scanning %p to %p\n",ptr,ptr+sz);
    printf("<M> minptr=%p, maxptr=%p\n",_gc.minPtr,_gc.maxPtr);
    void** p = cast(void**)ptr;
    for (size_t i=0; i<5; ++i) {
        if (potentialPointer(*(p+i)))
            q.enqueue(*(p+i));
    }
}

//Mark part of the heap
void markRecursive(void* root) {
    printf("<M> marking %p\n",root);
    auto rp = _gc.secondaryFL.regionOf(root);
    printf("<M> rp = %p\n",rp);
    if (rp is null) return;
    if (rp.color == (_gc.epoch % 3)) {
        printf("<M> no need to color region\n");
        return;
    }
    version (assert) gcAssert(rp.color == (_gc.epoch-1)%3);
    rp.color = _gc.epoch % 3;
    printf("<M> changed color of %p\n",rp.ptr);
    PointerQueue pq;
    scanForPointers(rp.ptr, rp.size, &pq);
    pq.iterDequeue((ptr) {
            markRecursive(ptr);
        });
}

bool potentialPointer(void* p) {
    return p >= _gc.minPtr && p < _gc.maxPtr;
}

void incrementEpoch() {
    _gc.epoch++;
}

//increment the epoch before calling this
void verifyRecursive(InjectorData* fndatahead, Freelist* fl) {
    
    debug (GC_PROFILE) {
        clock_t start, stop;
        start = clock();
    }
    
    InjectorData* idata = fndatahead;
    while (idata !is null) {
        for (int i=0; i<idata.npayloads; ++i)
            idata.payload[i].updateConnections(fl);
        idata = idata.prev;
    }
    
    Freelist.Region** globs;
    
    size_t nglobs = injector_scan_globals(&globs);
    
    for (int i=0; i<nglobs; ++i) {
        globs[i].updateConnections(fl);
    }
    
    if (globs !is null) clib.free(globs);
    
    debug (GC_PROFILE) {
        stop = clock();
        verifyTime += (stop-start);
    }
    
}

void verifyFunctions(InjectorData* fndatahead, Freelist* fl) {
    InjectorData* idata = fndatahead;
    bool changes;
    while (idata !is null) {
        if (idata.counter > _gc.verifyThreshold) {
            debug (USAGE) printf("<M> verifying roots of %p\n",idata.return_ptr);
            changes = true;
            size_t n;
            for (void** ptr=idata.barrier.pbot; ptr<idata.barrier.ptop; ++ptr) {
                if (potentialPointer(*ptr)) {
                    auto pp = fl.regionOf(*ptr);
                    if (pp !is null) {
                        if (n >= idata.psz) {
                            idata.payload = cast(injector_payload_t*)clib.realloc(idata.payload, (n+2) * injector_payload_t.sizeof);
                            idata.psz += 2;
                        }
                        debug (USAGE) printf("<M> root found (%p)\n",pp);
                        idata.payload[n++] = pp;
                    }
                }
            }
            idata.counter = 0;
            idata.npayloads = n;
        }
        idata = idata.prev;
    }
    if (changes || _gc.collectStartThreshold()) {
        _gc.fullCollect();
    }
        
}
