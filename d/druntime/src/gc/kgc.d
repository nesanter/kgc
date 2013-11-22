module gc.gc;

//debug = USAGE;
version = SINGLE_COLLECT;
//version = NOGC;

enum GCType { NONE, NEW }
version (NOGC) enum GCType _gctype = GCType.NONE;
else enum GCType _gctype = GCType.NEW;

static if (_gctype == GCType.NEW) {
    import gc.util.misc;
    import gc.util.freelists;
    import gc.util.t_main : yield;
    import gc.util.t_marker;
    import gc.util.injector;
    static import gc.util.marking;
    static import gc.util.grapher;
    static import core.memory;
    private alias BlkAttr = core.memory.GC.BlkAttr;
    import core.stdc.stdio;
    import core.sync.mutex;
    import core.sync.semaphore;
    import slib = core.stdc.string;
}

debug (USAGE) import core.stdc.stdio;

package {
    extern (C) void onOutOfMemoryError();
    extern (C) void onInvalidMemoryOperationError();
}
private {
    extern (C) void rt_finalize2(void* p, bool det, bool resetMemory);
}

/*
 *  The Kool GC
 *   (A variation on VCGC by Huelsbergen and Winterbottom)
 * 
 * 
 *  ---remember this---
 *    it might be possible to add a third thread, the stack scanner
 *    that runs while the marker thread marks
 *    and appends potential pointers to the root set
 *    the root set would become a set of pointer-pointers
 *    that remember spots where there were pointers before
 *    things to think about:
 *      ensuring the marker doesn't unknowingly scan something
 *      that is no longer our memory (e.g. previously used stack space)
 * 
 */


static if (_gctype == GCType.NONE) {
    import clib = core.stdc.stdlib;
    
    struct BlkInfo {
        void*  base;
        size_t size;
        uint   attr;
    }
    struct Range {
        void* pbot, ptop;
    }
    
} else static if (_gctype == GCType.NEW) {
    final class GCMutex : Mutex {}
}


class KGC
{    
    
    size_t disabled;
    
    enum size_t GC_EXTRA_SIZE = uint.sizeof;
    
    static if (_gctype == GCType.NONE) {
        __gshared size_t bytesAllocated;
        __gshared size_t bytesReleased;
    } else static if (_gctype == GCType.NEW) {
        enum real GC_FL_BUFFER_INIT = 0.0;
        public {
            __gshared ubyte epoch = 2;
            __gshared Freelist primaryFL;
            __gshared void* minPtr, maxPtr;
            __gshared PointerMap flCache;
            __gshared PointerQueue freeQueue, miscRootQueue;
            //Ranges are stored in a raw array, not a linked list
            __gshared Range* ranges, bounds;
            __gshared size_t nranges, nbounds;
            
            __gshared Freelist secondaryFL;
            __gshared PointerQueue miscRootQueueCopy;
            __gshared RootSet rootSetA, rootSetB;
            __gshared Range* rangesCopy;
            __gshared size_t nrangesCopy;
            __gshared bool rangesDirty;
            
            __gshared GCMutex mutatorLock, freeQueueLock;
            __gshared byte[__traits(classInstanceSize, GCMutex)] mutexStorage, mutexStorage2;
            
            /* The progess lock works like this:
             *   When no collect is in progress:
             *     The mutex is inactive (ALPHA)
             *     collectInProgress is OFF
             *   When a collect begins:
             *     collectInProgress is ON (set by mutator)
             *     the marker acquires the mutex (BETA)
             *   At the end of the collect:
             *     the marker sets collectInProgress to OFF or CONTINUE
             *     the marker transfers the mutex (GAMMA)
             *     the sweeper changes CONTINUE to ON, if necessary
             *     the sweeper synchronizes with the marker (ALPHA)
             *   To initiate a collect:
             *     Lock the mutex
             *     If the mutex is inactive (ALPHA),
             *       if collectInProgress is OFF
             *         set it to ON
             *         launch/wake the workers
             *     else a collect is already in progress
             *     Unlock the mutex
             *   To wait for a collect to complete
             *     use the wait() method of the mutex
             */
            __gshared QStateMutex progressLock;
            
            __gshared CollectMode collectInProgress;
            
            //these control the threshold
            __gshared size_t bytesAllocated; //this must only increase
            __gshared size_t bytesReleased; //ditto
            enum size_t collectStart = 4000;
            enum size_t collectStop = 3500;
            
        }
    }
    
    void initialize() {
        debug (USAGE) printf("<GC> initialize ()\n");
        
        static if (_gctype == GCType.NEW) {
            /*
            primaryFL = cast(Freelist*)clib.malloc(Freelist.sizeof);
            if (!primaryFL)
                onOutOfMemoryError();
            secondaryFL = cast(Freelist*)clib.malloc(Freelist.sizeof);
            if (!secondaryFL)
                onOutOfMemoryError();
            freeQueue = cast(PointerQueue*)clib.malloc(PointerQueue.sizeof);
            if (!freeQueue)
                onOutOfMemoryError();
            miscRootQueue = cast(PointerQueue*)clib.malloc(PointerQueue.sizeof);
            if (!miscRootQueue)
                onOutOfMemoryError();
            */
            
            mutexStorage[] = GCMutex.classinfo.init[];
            mutatorLock = cast(GCMutex)mutexStorage.ptr;
            mutatorLock.__ctor();
            mutexStorage2[] = GCMutex.classinfo.init[];
            freeQueueLock = cast(GCMutex)mutexStorage2.ptr;
            freeQueueLock.__ctor();
            
            primaryFL.initialize(GC_FL_BUFFER_INIT, &flCache);
            secondaryFL.initialize(GC_FL_BUFFER_INIT, &flCache);
            freeQueue.initialize();
            miscRootQueue.initialize();
            rootSetA.initialize();
            rootSetB.initialize();
            
            init_workers();
        }
    }
    
    void Dtor() {
        debug (USAGE) printf("<GC> Dtor ()\n");
        static if (_gctype == GCType.NEW) {
            
            //stop_workers();
            join_workers(); // <--- do this first otherwise it messes up sweeper
            
            //primaryFL.freeAll(); <--- apparently you shouldn't do this either
            //                            because it frees the main thread
            //                            from under itself
            //                            note: the normal gc doesn't do this either
            //secondaryFL.freeAll();  <--- don't need to free cuz it is subset of primary
            
            //substitute for above two lines:
            primaryFL.freeAllNodes();
            
            //clib.free(primaryFL);
            //clib.free(secondaryFL);
            /*
            size_t fql = freeQueue.length;
            if (fql > 0) {
                void** ptrs = cast(void**)clib.malloc(fql * (void*).sizeof);
                freeQueue.dequeue(ptrs);
                foreach (i; 0 .. fql)
                    clib.free(ptrs[i]);
                clib.free(ptrs);
            }
            */
            freeQueue.freeNodes();
            //clib.free(freeQueue);
            /*
            fql = miscRootQueue.length;
            if (fql > 0) {
                void** ptrs = cast(void**)clib.malloc(fql * (void*).sizeof);
                miscRootQueue.dequeue(ptrs);
                foreach (i; 0 .. fql)
                    clib.free(ptrs[i]);
                clib.free(ptrs);
            }
            */
            miscRootQueue.freeNodes();
            miscRootQueueCopy.freeNodes();
            rootSetA.freeNodes();
            rootSetB.freeNodes();
            //clib.free(miscRootQueue);
            if (ranges !is null)
                clib.free(ranges);
            if (rangesCopy !is null)
                clib.free(rangesCopy);
        }
    }
    
    void enable() {
        debug (USAGE) printf("<GC> enable ()\n");
        static if (_gctype == GCType.NEW) {
            mutatorLock.lock();
            scope (exit) mutatorLock.unlock();
        }
        
        assert(disabled > 0);
        disabled--;
    }
    
    void disable() {
        debug (USAGE) printf("<GC> disable ()\n");
        static if (_gctype == GCType.NEW) {
            mutatorLock.lock();
            scope (exit) mutatorLock.unlock();
        }
        
        disabled++;
    }
    
    uint getAttr(void* p) {
        debug (USAGE) printf("<GC> getAttr (%p)\n",p);
        static if (_gctype == GCType.NONE) {
            onInvalidMemoryOperationError();
            return 0;
        } else static if (_gctype == GCType.NEW) {
            
            size_t asz;
            
            {
                mutatorLock.lock();
                scope (exit) mutatorLock.unlock();
                
                asz = primaryFL.capacity(p);
                //if (asz == 0) asz = secondaryFL.capacity(p);
                if (asz == 0) return 0;
            }
            
            return getBits(p, asz-GC_EXTRA_SIZE);
        } else
            return 0;
    }
    
    uint setAttr(void* p, uint mask) {
        debug (USAGE) printf("<GC> setAttr (%p,%u)\n",p,mask);
        static if (_gctype == GCType.NONE) {
            onInvalidMemoryOperationError();
            return 0;
        } else static if (_gctype == GCType.NEW) {
            
            size_t asz;
            
            {
                mutatorLock.lock();
                scope (exit) mutatorLock.unlock();
                
                asz = primaryFL.capacity(p);
                //if (asz == 0) asz = secondaryFL.capacity(p);
                if (asz == 0) return 0;
            }
            
            return orBits(p, asz-GC_EXTRA_SIZE, mask);
        } else
            return 0;
    }
    
    uint clrAttr(void* p, uint mask) {
        debug (USAGE) printf("<GC> clrAttr (%p,%u)\n",p,mask);
        static if (_gctype == GCType.NONE) {
            onInvalidMemoryOperationError();
            return 0;
        } else static if (_gctype == GCType.NEW) {

            size_t asz;

            {
                mutatorLock.lock();
                scope (exit) mutatorLock.unlock();
                
                asz = primaryFL.capacity(p);
                //if (asz == 0) asz = secondaryFL.capacity(p);
                if (asz == 0) return 0;
            }
            
            return andBits(p, asz-GC_EXTRA_SIZE, ~mask);
        } else
            return 0;
    }
    
    void* malloc(size_t size, uint bits = 0, size_t* alloc_size = null) {
        debug (USAGE) printf("<GC> malloc (%lu,%u,%p)\n",size,bits,alloc_size);
        size_t localAllocSize;
        if (alloc_size is null)
            alloc_size = &localAllocSize;
        static if (_gctype == GCType.NONE) {
            void* p = clib.malloc(size+GC_EXTRA_SIZE);
            *alloc_size = size+GC_EXTRA_SIZE;                
        } else static if (_gctype == GCType.NEW) {
            mutatorLock.lock();
            scope (exit) mutatorLock.unlock();
            
            Freelist.Region* rp;
            void* p = primaryFL.grab(size, alloc_size, &rp);
            
            if (p !is null && (p < minPtr || minPtr is null))
                minPtr = p;
            if (p !is null && (p+*alloc_size) > maxPtr)
                maxPtr = p+*alloc_size;
            
            if (disabled == 0)
                inject_outer(rp);
        } else
            void* p = null;
        //set bits
        setBits(p, *alloc_size-GC_EXTRA_SIZE, bits); //put at end of true block
        
        bytesAllocated += *alloc_size;
        
        
        
        return p;
    }
    
    void* calloc(size_t size, uint bits = 0, size_t* alloc_size = null, string fname = __FUNCTION__) {
        debug (USAGE) printf("<GC> calloc (%lu,%u,%p)\n",size,bits,alloc_size);
        static if (_gctype == GCType.NONE) {
            void* p = clib.calloc(1, size);
        } else static if (_gctype == GCType.NEW) {
            //no need to lock since KGC.malloc locks
            void* p = malloc(size, bits, alloc_size);
            slib.memset(p, 0, size);
        } else
            void* p = null;
        return p;
    }
    
    void* realloc(void* p, size_t size, uint bits = 0, size_t* alloc_size = null) {
        debug (USAGE) printf("<GC> realloc (%lu,%u,%p)\n",size,bits,alloc_size);
        size_t localAllocSize, new_alloc_size;
        if (alloc_size is null)
            alloc_size = &localAllocSize;
        static if (_gctype == GCType.NONE) {
            void* newp = clib.realloc(p, size+GC_EXTRA_SIZE);
            *alloc_size = size+GC_EXTRA_SIZE;
            setBits(newp, *alloc_size-GC_EXTRA_SIZE, bits);
            return newp;
        } else static if (_gctype == GCType.NEW) {
            
            void* newp;
            
            {
                mutatorLock.lock();
                scope (exit) mutatorLock.unlock();
                
                newp = primaryFL.regrab(p, size, alloc_size, &new_alloc_size);
                //if (newp is null) newp = secondaryFL.regrab(p, size, alloc_size);
            }
            
            setBits(newp, *alloc_size-GC_EXTRA_SIZE, bits);
            
            bytesAllocated += new_alloc_size;
            
            /* Not sure if this should inject
             * or search for an old inject
             * or what?
             */
            
            return newp;
        } else
            return null;
    }
    
    size_t extend(void* p, size_t minsize, size_t maxsize) {
        debug (USAGE) printf("<GC> extend (%p,%lu,%lu)\n",p,minsize,maxsize);
        static if (_gctype == GCType.NONE) {
            return 0;
        } else static if (_gctype == GCType.NEW) {
            //with current allocation scheme this is heavily dependent
            //on the chosen blocksize
            
            bool fail;
            size_t ext;
            
            {
                mutatorLock.lock();
                scope (exit) mutatorLock.unlock();
                
                ext = primaryFL.extend(p, minsize, maxsize, &fail);
                //if (ext == 0 && !fail) ext = secondaryFL.extend(p, minsize, maxsize, &fail);
            }
            
            if (fail) printf("EXTEND FAILED\n");
            else printf("EXTEND SUCEEDED\n");
            return ext;
        } else
            return 0;
    }
    
    size_t reserve(size_t size) {
        debug (USAGE) printf("<GC> reserve (%lu)\n",size);
        static if (_gctype == GCType.NONE) {
            return 0;
        } else static if (_gctype == GCType.NEW) {
            return 0;
        } else 
            return 0;
    }
    
    void free(void* p) {
        debug (USAGE) printf("<GC> free (%p)\n",p);
        static if (_gctype == GCType.NONE) {
            clib.free(p);
        } else static if (_gctype == GCType.NEW) {
            
            {
                
                //need to lock both mutexes
                //however sweeper need only lock the second
                mutatorLock.lock();
                scope (exit) mutatorLock.unlock();
                
                freeQueueLock.lock();
                scope (exit) freeQueueLock.unlock();
            
                //if (primaryFL.free(p)) return;
                //otherwise it's in the secondary list
                //and we need to wait until the end of the epoch
                
                //above is wrong
                //we must always enqueue
                void* rptr = primaryFL.node(p);
                if (rptr !is null)
                    freeQueue.enqueue(rptr);
            }
            
        }
    }
    
    void* addrOf(void* p) {
        debug (USAGE) printf("<GC> addrOf (%p)\n",p);
        static if (_gctype == GCType.NONE) {
            return null;
        } else static if (_gctype == GCType.NEW) {
            
            void* base;
            
            {
                mutatorLock.lock();
                scope (exit) mutatorLock.unlock();
                
                base = primaryFL.addrOf(p);
                //if (base !is null) return base;
                //base = secondaryFL.addrOf(p);
            }
            
            return base; //either null or the actual thing
        } else
            return null;
    }
    
    size_t sizeOf(void* p) {
        debug (USAGE) printf("<GC> sizeOf (%p)\n",p);
        static if (_gctype == GCType.NONE) {
            return 0;
        } else static if (_gctype == GCType.NEW) {
            
            size_t size;
            
            {
                mutatorLock.lock();
                scope (exit) mutatorLock.unlock();
                
                size = primaryFL.size(p);
                //if (size > 0) return size;
                //size = secondaryFL.size(p);
            }
            
            return size;
        } else
            return 0;
    }
    
    BlkInfo query(void* p) {
        debug (USAGE) printf("<GC> query (%p)\n",p);
        auto rp = primaryFL.regionOf(p);
        if (rp is null) return BlkInfo.init;
        return BlkInfo(rp.ptr, rp.capacity, getBits(rp.ptr, rp.capacity));
    }
    
    void check(void* p) {
        debug (USAGE) printf("<GC> check (%p)\n",p);
        static if (_gctype == GCType.NONE) {
            //do nothing
        } else static if (_gctype == GCType.NEW) {
            
            {
                mutatorLock.lock();
                scope (exit) mutatorLock.unlock();
                
                assert(primaryFL.size(p) > 0/* || secondaryFL.size(p) > 0*/);
            }
        }
    }
    
    void addRoot(void* p) {
        debug (USAGE) printf("<GC> addRoot (%p)\n",p);
        static if (_gctype == GCType.NONE) {
            //do nothing
        } else static if (_gctype == GCType.NEW) {
            
            {
                mutatorLock.lock();
                scope (exit) mutatorLock.unlock();
                
                miscRootQueue.enqueue(p);
            }
        }
    }
    
    void removeRoot(void* p) {
        debug (USAGE) printf("<GC> removeRoot (%p)\n",p);
        static if (_gctype == GCType.NONE) {
            //do nothing
        } else static if (_gctype == GCType.NEW) {
            
            {
                mutatorLock.lock();
                scope (exit) mutatorLock.unlock();
                
                miscRootQueue.remove(p);
            }
        }
    }
    
    @property int delegate(int delegate(ref void*)) rootIter() {
        debug (USAGE) printf("<GC> rootIter ()\n");
        static if (_gctype == GCType.NEW) {
            return &miscRootQueue.iter!true;
        } else
            return null;
    }
        
    void addRange(void* p, size_t sz) {
        debug (USAGE) printf("<GC> addRange (%p,%lu)\n",p,sz);
        static if (_gctype == GCType.NONE) {
            //do nothing
        } else static if (_gctype == GCType.NEW) {
            //this is a fairly slow operation
            //but really shouldn't be called all that often
            
            {
                mutatorLock.lock();
                scope (exit) mutatorLock.unlock();
                
                foreach (i; 0 .. nranges) {
                    if (ranges[i].pbot is null) {
                        ranges[i] = Range(p, p+sz);
                        return;
                    }
                }
                if (ranges is null) ranges = cast(Range*)clib.malloc(Range.sizeof);
                else ranges = cast(Range*)clib.realloc(ranges, (nranges+1) * Range.sizeof);
                ranges[nranges++] = Range(p, p+sz);
                
                rangesDirty = true;
                
                foreach (size_t i; 0 .. nranges) {
                    printf("%lu (%p to %p)\n",i,ranges[i].pbot,ranges[i].ptop);
                }
            }
            
        }
    }
    
    void removeRange(void* p) {
        debug (USAGE) printf("<GC> removeRange (%p)\n",p);
        static if (_gctype == GCType.NONE) {
            //do nothing
        } else static if (_gctype == GCType.NEW) {
            
            {
                mutatorLock.lock();
                scope (exit) mutatorLock.unlock();
                
                foreach (i; 0 .. nranges) {
                    if (ranges[i].ptop == p) {
                        ranges[i] = Range(null, null);
                        return;
                    }
                }
            }
            
        }
    }
    
    @property int delegate(int delegate(ref Range)) rangeIter() {
        debug (USAGE) printf("<GC> rangeIter ()\n");
        static if (_gctype == GCType.NEW) {
            return &_rangeIter;
        } else
            return null;
    }
    
    int _rangeIter(int delegate(ref Range) dg) {
        static if (_gctype == GCType.NEW) {
            int result = 0;
            foreach (i; 0 .. nranges) {
                result = dg(ranges[i]);
                if (result) break;
            }
            return result;
        } else
            return 0;
    }
    
    bool fullCollect() {
        debug (USAGE) printf("<GC> fullCollect ()\n");
        
        static if (_gctype == GCType.NEW) {
            if (progressLock.inactive) {
                if (collectInProgress == CollectMode.OFF) {
                    collectInProgress = CollectMode.ON;
                    if (workersActive()) wake_workers();
                    else launch_workers();
                    return true;
                }
            }
            return false;
        } else
            assert(0);
    }
    
    static if (_gctype == GCType.NEW) {
        package void finalize(void* p, size_t sz) {
            debug (USAGE) printf("<GC> finalize (%p,%lu)\n",p);
            if (getBits(p, sz) && BlkAttr.FINALIZE) {
                rt_finalize2(p, false, false);
            }
        }
    }
    
    bool wait(bool full) {
        debug (USAGE) printf("<GC> wait ()\n");
        static if (_gctype == GCType.NEW) {
            if (full) {
                while (progressLock.wait(() { return collectInProgress != CollectMode.OFF; })) {}
                return true;
            } else {
                return progressLock.wait(() { return collectInProgress != CollectMode.OFF; });
            }
        } else
            return true;
    }
    
    package bool collectStartThreshold() {
        return (bytesAllocated-bytesReleased) > collectStartThreshold;
    }
    
    package bool collectStopThreshold() {
        version (SINGLE_COLLECT) {
            return false;
        } else {
            return (bytesAllocated-bytesReleased) > collectStopThreshold;
        }
    }
    
    void fullCollectNoStack() {
        debug (USAGE) printf("<GC> fullCollectNoStack ()\n");
    }
    
    void minimize() {
        debug (USAGE) printf("<GC> minimize ()\n");
        static if (_gctype == GCType.NEW) {
            primaryFL.minimize(); //releases free regions
            //DON'T minimize secondaryFL
            //(this wouldn't even help since it's mostly used anyways)
        }
    }
    
    size_t getBytesAllocated() nothrow {
        return bytesAllocated;
    }
    size_t getBytesReleased() nothrow {
        return bytesReleased;
    }
    

    private void setBits(void* p, size_t sz, uint bits) {
        *cast(uint*)(p+sz) = bits;
    }
    private uint getBits(void* p, size_t sz) {
        return *cast(uint*)(p+sz);
    }
    private uint orBits(void* p, size_t sz, uint bits) {
        *cast(uint*)(p+sz) |= bits;
        return *cast(uint*)(p+sz);
    }
    private uint andBits(void* p, size_t sz, uint bits) {
        *cast(uint*)(p+sz) &= bits;
        return *cast(uint*)(p+sz);
    }
    
    void registerFunction(string name = __FUNCTION__) {
        gc.util.grapher.graph_add_fname(name);
    }
    
    version (GCOUT) {
        void graph_output_dot(bool full, bool nointerconnect = false) {
            gc.util.marking.verifyRecursive(injector_head, &primaryFL);
            version (GRAPH_FULL) {
                if (full)
                    gc.util.grapher.graph_output_dot(injector_head, &primaryFL, injector_head_dead, nointerconnect);
                else
                    gc.util.grapher.graph_output_dot(injector_head, &primaryFL, null, nointerconnect);
            } else {
                gc.util.grapher.graph_output_dot(injector_head, &primaryFL);
            }
        }
    }
    
    //debug
    void dump() {
        static if (_gctype == GCType.NEW) {
            printf("+--KGC INFO---\n");
            printf("| EPOCH: %hhu\n",epoch);
            printf("| ACTIVE BYTES: %lu (%lu/%lu)\n",
                    bytesAllocated-bytesReleased,
                    bytesAllocated,
                    bytesReleased
                );
            final switch (collectInProgress) {
                case CollectMode.OFF: printf("| COLLECT: OFF\n"); break;
                case CollectMode.CONTINUE: printf("| COLLECT: CONTINUE\n"); break;
                case CollectMode.ON: printf("| COLLECT: ON\n"); break;
            }
            printf("| NRANGES: %lu (%lu bytes)\n",nranges,getRangesSize());
            printf("+-------------\n");
            primaryFL.print();
            printf("+-------------\n");
        }
    }
}

void mem_free(void* p) {
    clib.free(p);
}

void* mem_alloc(size_t sz) {
    return clib.malloc(sz);
}
