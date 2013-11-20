/* 
 *  Marking routines
 */

module gc.marking;

//debug = USAGE;

import gc.freelists;
import gc.proxy;
import gc.misc;
import gc.injector;
import core.stdc.stdlib : abort;

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
    
}
