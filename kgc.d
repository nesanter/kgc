module gc.gc;

import gc.misc;
import gc.freelists;
import t_main = gc.t_main : yield;
import gc.t_marker;
//import gc.t_sweeper;

import core.sync.mutex;
import core.atomic;

package {
    extern (C) void onOutOfMemoryError();
    extern (C) void onInvalidMemoryOperationError();
}

/*
 *  The Kool GC
 *   (A variation on VCGC by Huelsbergen and Winterbottom)
 * 
 */

version = SINGLE_COLLECT;


debug = USAGE;
debug = GCPRINTF;
enum GCType { NONE, NEW }
immutable GCType _gctype = GCType.NEW;

package __gshared GCError _gcerror;
private __gshared byte[__traits(classInstanceSize, GCError)] _gcerrorStorage;

package __gshared GCAssertError _gcasserterror;
private __gshared byte[__traits(classInstanceSize, GCAssertError)] _gcasserterrorStorage;


debug (GCPRINTF) import core.stdc.stdio;

static if (_gctype == GCType.NONE)
    import clib = core.stdc.stdlib;
static if (_gctype == GCType.NEW) {
    import slib = core.stdc.string;
}

final class GCMutex : Mutex {}

class KGC
{    
    
    size_t disabled;
    
    immutable size_t GC_EXTRA_SIZE = uint.sizeof;
    
    static if (_gctype == GCType.NEW) {
        immutable real GC_FL_BUFFER_INIT = 0.5;
        package {
            __gshared ubyte epoch = 2;
            __gshared Freelist* primaryFL;
            __gshared PointerQueue* freeQueue, miscRootQueue;
            //Ranges are stored in a raw array, not a linked list
            __gshared Range* ranges;
            __gshared size_t nranges;
            
            __gshared Freelist* secondaryFL;
            __gshared PointerQueue* miscRootQueueCopy;
            __gshared Range* rangesCopy;
            __gshared bool rangesDirty;
            
            __gshared GCMutex mutatorLock, freeQueueLock;
            __gshared byte[__traits(classInstanceSize, GCMutex)] mutexStorage, mutexStorage2;
            
            __gshared CollectMode collectInProgress;
            
            //these control the threshold
            __gshared size_t bytesAllocated; //this must only increase
            __gshared size_t bytesReleased; //ditto
            immutable size_t collectStart = 4000;
            immutable size_t collectStop = 3500;
            
        }
    }
    
    void initialize() {
        debug (USAGE) printf("<GC> initialize ()\n");
        
        _gcerrorStorage[] = GCError.classinfo.init[];
        _gcerror = cast(GCError)_gcerrorStorage.ptr;
        _gcerror.__ctor();
        
        version (assert) {
            _gcasserterrorStorage[] = GCAssertError.classinfo.init[];
            _gcasserterror = cast(GCAssertError)_gcasserterrorStorage.ptr;
            _gcasserterror.__ctor();
        } else version (unittest) {
            _gcasserterrorStorage[] = GCAssertError.classinfo.init[];
            _gcasserterror = cast(GCAssertError)_gcasserterrorStorage.ptr;
            _gcasserterror.__ctor();
        }
        
        static if (_gctype == GCType.NEW) {
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
            
            mutexStorage[] = GCMutex.classinfo.init[];
            mutatorLock = cast(GCMutex)mutexStorage.ptr;
            mutatorLock.__ctor();
            mutexStorage2[] = GCMutex.classinfo.init[];
            freeQueueLock = cast(GCMutex)mutexStorage2.ptr;
            freeQueueLock.__ctor();
            
            primaryFL.initialize(GC_FL_BUFFER_INIT);
            secondaryFL.initialize(GC_FL_BUFFER_INIT);
            freeQueue.initialize();
            miscRootQueue.initialize();
            
            init_workers();
            printf("init complete\n");
        }
    }
    
    void Dtor() {
        debug (USAGE) printf("<GC> Dtor ()\n");
        static if (_gctype == GCType.NEW) {
            
            //stop_workers();
            
            //primaryFL.freeAll(); <--- apparently you shouldn't do this either
            //                            because it frees the main thread
            //                            from under itself
            //                            note: the normal gc doesn't do this either
            //secondaryFL.freeAll();  <--- don't need to free cuz it is subset of primary
            
            //substitute for above two lines:
            primaryFL.freeAllNodes();
            
            clib.free(primaryFL);
            clib.free(secondaryFL);
            size_t fql = freeQueue.length;
            if (fql > 0) {
                void** ptrs = cast(void**)clib.malloc(fql * (void*).sizeof);
                freeQueue.dequeue(ptrs);
                foreach (i; 0 .. fql)
                    clib.free(ptrs[i]);
                clib.free(ptrs);
            }
            clib.free(freeQueue);
            fql = miscRootQueue.length;
            if (fql > 0) {
                void** ptrs = cast(void**)clib.malloc(fql * (void*).sizeof);
                miscRootQueue.dequeue(ptrs);
                foreach (i; 0 .. fql)
                    clib.free(ptrs[i]);
                clib.free(ptrs);
            }
            clib.free(miscRootQueue);
            
            join_workers();
        }
    }
    
    void enable() {
        debug (USAGE) printf("<GC> enable ()\n");
        
        mutatorLock.lock();
        scope (exit) mutatorLock.unlock();
        
        assert(disabled > 0);
        disabled--;
    }
    
    void disable() {
        debug (USAGE) printf("<GC> disable ()\n");
        
        mutatorLock.lock();
        scope (exit) mutatorLock.unlock();
        
        disabled++;
    }
    
    uint getAttr(void* p) {
        debug (USAGE) printf("<GC> getAttr (%p)\n",p);
        static if (_gctype == GCType.NONE) {
            onInvalidMemoryOperationError();
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
            
            void* p = primaryFL.grab(size, alloc_size);
        } else
            void* p = null;
        //set bits
        setBits(p, *alloc_size-GC_EXTRA_SIZE, bits); //put at end of true block
        
        bytesAllocated += *alloc_size;
        
        return p;
    }
    
    void* calloc(size_t size, uint bits = 0, size_t* alloc_size = null) {
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
        return BlkInfo.init;
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
            return &miscRootQueue.iter;
        }
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
                    if (ranges[i].ptop is null) {
                        ranges[i] = Range(p, p+sz);
                        return;
                    }
                }
                if (ranges is null) ranges = cast(Range*)clib.malloc(Range.sizeof);
                else ranges = cast(Range*)clib.realloc(p, (nranges+1) * Range.sizeof);
                ranges[nranges++] = Range(p, p+sz);
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
        }
        return null;
    }
    
    int _rangeIter(int delegate(ref Range) dg) {
        int result = 0;
        foreach (i; 0 .. nranges) {
            result = dg(ranges[i]);
            if (result) break;
        }
        return result;
    }
    
    bool fullCollect() {
        debug (USAGE) printf("<GC> fullCollect ()\n");
        
        {
            mutatorLock.lock();
            scope (exit) mutatorLock.unlock();
            
            if (collectInProgress != CollectMode.OFF) {
                return false;
            }
            
            collectInProgress = CollectMode.ON;
            
            bool ml, sl;
            if (!workersLaunched()) launch_workers(ml, sl);
            else wake_workers();
        }
        
        return true;
    }
    
    void wait() {
        debug (USAGE) printf("<GC> wait ()\n");
        
        while (collectInProgress != CollectMode.OFF) {
            t_main.yield();
        }
    }
    
    bool collectStartThreshold() {
        return (bytesAllocated-bytesReleased) > collectStartThreshold;
    }
    
    bool collectStopThreshold() {
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
    
    size_t getBytesAllocated() {
        return bytesAllocated;
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
    
    //debug
    void dump() {
        static if (_gctype == GCType.NEW) {
            printf("EPOCH: %hhu\n",epoch);
            printf("USED BYTES: %lu\n",bytesAllocated);
            printf("PRIMARY:\n");
            primaryFL.print();
            printf("SECONDARY:\n");
            secondaryFL.print();
        }
    }
}

void mem_free(void* p) {
    clib.free(p);
}

void* mem_alloc(size_t sz) {
    return clib.malloc(sz);
}
