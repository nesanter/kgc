/*
 *  Freelists implementation
 * 
 *  Holds blocks of data
 * 
 *  Must support the following operations:
 *    + grab -- supplies a block to the mutator
 *    + release -- marks a block as free
 *  
 */

module gc.freelists;

//debug = USAGE;
version = PTRMAP;

import gc.proxy;
import gc.misc : gcAssert, onGCFatalError;
import gc.gc : onOutOfMemoryError, onInvalidMemoryOperationError, KGC, mem_free, mem_alloc;
import gc.marking : potentialPointer;
//import clib = core.stdc.stdlib;
import slib = core.stdc.string;
import clib = core.stdc.stdlib;

version (unittest) import core.stdc.stdio : printf;
else debug (USAGE) import core.stdc.stdio : printf;

//this currently uses a very simple method
//and is not thread-safe

struct Freelist {
    
    struct Region {
        void* ptr;
        ubyte color;
        size_t size, capacity;
        Region* prev, prev2;
        
        Region** connections;
        size_t nconnections;
        
        bool fake_free;
        
        this(void* ptr, size_t size, size_t capacity, Region* prev) {
            this.ptr = ptr;
            this.color = _gc.epoch % 3;
            this.size = size;
            this.capacity = capacity;
            this.prev = prev;
            this.prev2 = null;
            this.connections = null;
            this.nconnections = 0;
            this.fake_free = false;
        }
        
        void addConnection(Region* r) {
            printf("add %p\n",r);
            printf("this = %p\n",this);
            printf("connections = %p (%lu)\n",connections,nconnections);
            if (connections is null)
                connections = cast(Region**)clib.malloc((Region*).sizeof);
            else
                connections = cast(Region**)clib.realloc(connections, (nconnections+1) * (Region*).sizeof);
            connections[nconnections++] = r;
        }
        
        void updateConnections(Freelist* f) {
            //printf("here (%p)\n",this);
            if (color == _gc.epoch % 3) return;
            color = _gc.epoch % 3;
            size_t found;
            for (void** p=cast(void**)ptr; p<ptr+size; ++p) {
                if (potentialPointer(*p)) {
                    Region* rp = f.regionOf(*p);
                    if (rp !is null) {
                        if (found >= nconnections)
                            connections = cast(Region**)clib.realloc(connections, (found+1)*(Region*).sizeof);
                        connections[found++] = rp;
                    }
                }
            }
            nconnections = found;
            for (int i=0; i<nconnections; ++i)
                connections[i].updateConnections(f);
        }
    }
    
    Region* tail;
    
    //cannot allocate into free space with more than MAX_WASTE unused bytes
    immutable size_t MAX_WASTE = 256;
    
    real buffer; //amount to over-allocate
    
    version (unittest) size_t length;
    
    version (PTRMAP) PointerMap* pm;
    
    void initialize(real buf, PointerMap* p) {
        gcAssert(buf >= 0);
        buffer = (1+buf);
        tail = null;
        pm = p;
    }
    
    //always uses primary
    void* grab(size_t sz, size_t* alloc_size = null, Region** rp=null) {
        debug (USAGE) printf("<GC> Freelist.grab (%lu,%p)\n",sz,alloc_size);
        size_t bytes = cast(size_t)(sz * buffer)+KGC.GC_EXTRA_SIZE;
        
        if (sz == 0) return null;

        if (tail is null) {
            tail = cast(Region*)mem_alloc(Region.sizeof);
            if (tail is null)
                onOutOfMemoryError();
            *tail = Region(mem_alloc(bytes), sz, bytes, null);
            if (tail.ptr is null)
                onOutOfMemoryError();
            if (alloc_size != null)
                *alloc_size += tail.capacity;
            version (unittest) length++;
            //printf("malloc'd %p\n",tail.ptr);
            version (PTRMAP) pm.add(tail.ptr, tail);
            if (rp !is null) *rp = tail;
            return tail.ptr;
        }
        
        Region* r = tail;
        while (true) {
            
            if (r.capacity >= bytes && r.size == 0 && (r.capacity - bytes) <= MAX_WASTE) {
                r.size = sz;
                if (alloc_size != null)
                    *alloc_size += r.capacity;
                //printf("malloc'd %p\n",r.ptr);
                version (PTRMAP) pm.add(r.ptr, r);
                if (rp !is null) *rp = r;
                return r.ptr;
            }
            
            if (r.prev is null)
                break;
            else
                r = r.prev;
        }
        
        r = cast(Region*)mem_alloc(Region.sizeof);
        if (r is null)
            onOutOfMemoryError();
        *r = Region(mem_alloc(bytes), sz, bytes, tail);
        if (r.ptr is null)
            onOutOfMemoryError();
        tail = r;
        
        if (alloc_size != null)
            *alloc_size += bytes;
        
        version (unittest) length++;
        //printf("malloc'd %p\n",tail.ptr);
        version (PTRMAP) pm.add(tail.ptr, tail);
        if (rp !is null) *rp = r;
        return tail.ptr;
    }
    
    //always uses primary
    size_t size(void* p) {
        debug (USAGE) printf("<GC> Freelist.size (%p)\n",p);
        Region* r = tail;
        while (r !is null) {
            if (r.ptr == p)
                return r.size;
            r = r.prev;
        }
        return 0;
    }
    
    //always uses primary
    size_t capacity(void* p) {
        debug (USAGE) printf("<GC> Freelist.capacity (%p)\n",p);
        Region* r = tail;
        while (r !is null) {
            if (r.ptr == p)
                return r.capacity;
            r = r.prev;
        }
        return 0;
    }
    
    //always uses primary
    void* node(void* p) {
        debug (USAGE) printf("<GC> Freelist.node (%p)\n",p);
        Region* r = tail;
        while (r !is null) {
            if (r.ptr == p)
                return r;
            r = r.prev;
        }
        return null;
    }
    
    //always uses primary
    //never called by GC
    bool release(void* p, size_t* free_size = null) {
        debug (USAGE) printf("<GC> Freelist.release (%p)\n",p);
        Region* r = tail;
        while (r !is null) {
            if (r.ptr == p) {
                if (r.size == 0) onInvalidMemoryOperationError();
                if (free_size !is null)
                    *free_size += r.capacity;
                r.size = 0;
                
                return true;
            }
            r = r.prev;
        }
        return false;
    }
    
    void releaseRegion(void* rp, size_t* free_size = null) {
        Region* r = cast(Region*)rp;
        if (r is null) {
            printf("BAD POINTER!\n");
            onGCFatalError();
        }
        //printf("releasing region %p\n",r.ptr);
        if (free_size !is null)
            *free_size += r.capacity;
        _gc.finalize(r.ptr, r.capacity);
        r.size = 0;
        
    }
    
    //create a snapshot of all used blocks
    //uses both
    void snapshot(Freelist* f) {
        debug (USAGE) printf("<GC> Freelist.snapshot (%p)\n",f);
        Region* r = tail;
        while (r !is null) {
            if (r.size > 0) {
                //if (rprev !is null)
                //    rprev.prev = r.prev;
                r.prev2 = f.tail;
                f.tail = r;
            }
            r = r.prev;
        }
    }
    
    //this isn't ever called in the current system
    bool free(void* p, size_t* free_size = null) {
        debug (USAGE) printf("<GC> Freelist.free (%p,%p)\n",p,free_size);
        Region* r = tail, rprev = null;
        while (r !is null) {
            if (r.ptr == p) {
                if (rprev !is null) {
                    rprev.prev = r.prev;
                } else {
                    tail = r.prev;
                }
                
                if (r.size > 0 && free_size !is null)
                    *free_size += r.capacity;
                
                mem_free(r.ptr);
                mem_free(r);
                version (unittest) length--;
                return true;
            }
            rprev = r;
        }
        return false;
    }
    
    //uses secondary
    void freeSweep(size_t* free_size) {
        debug (USAGE) printf("<GC> Freelist.freeSweep (%p)\n",free_size);
        Region* r = tail;
        size_t freed;
        ubyte free_color = (_gc.epoch-2)%3;
        while (r !is null) {
            if (r.color == free_color && r.size > 0) {
                freed += r.capacity;
                _gc.finalize(r.ptr, r.capacity);
                r.size = 0;
            }
            r = r.prev2;
        }
        if (free_size !is null)
            *free_size += freed;
        //tail = null;
    }
    
    void fakeSweep() {
        debug (USAGE) printf("<GC> Freelist.fakeSweep ()\n");
        Region* r = tail;
        ubyte free_color = (_gc.epoch-2)%3;
        while (r !is null) {
            if (r.color == free_color)
                r.fake_free = true;
            r = r.prev;
        }
    }
    
    // This used to be called but is now only used in the unittest
    void freeAll() {
        debug (USAGE) printf("<GC> Freelist.freeAll ()\n");
        Region* r = tail, rprev;
        while (r !is null) {
            mem_free(r.ptr);
            rprev = r.prev;
            mem_free(r);
            r = rprev;
        }
        tail = null;
        version (unittest) length = 0;
    }
    
    //this is called instead
    //uses primary
    void freeAllNodes() {
        debug (USAGE) printf("<GC> Freelist.freeAllNodes ()\n");
        Region* r = tail, rprev;
        while (r !is null) {
            rprev = r.prev;
            mem_free(r);
            r = rprev;
        }
        tail = null;
        version (unittest) length = 0;
    }
    
    //uses primary
    size_t minimize() {
        debug (USAGE) printf("<GC> Freelist.minimize ()\n");
        Region* r = tail, rprev, prev = null;
        size_t freed;
        while (r !is null) {
            rprev = r.prev;
            if (r.size == 0) {
                if (prev !is null)
                    prev.prev = r.prev;
                else
                    tail = r.prev;
                freed += r.capacity;
                mem_free(r.ptr);
                mem_free(r);
                version (unittest) length--;
            } else {
                prev = r;
            }
            r = rprev;
        }
        return freed;
    }
    
    //uses primary
    void* addrOf(void* p) {
        //find allocation block that holds p
        Region* r = tail;
        while (r !is null) {
            if (r.ptr <= p && p < r.ptr + r.size)
                return r.ptr;
            r = r.prev;
        }
        return null;
    }
    
    Region* regionOf(void* p) {
        Region* r;
        version (PTRMAP) {
            r = pm.query(p);
            if (r !is null)
                return r;
        }
        r = tail;
        while (r !is null) {
            if (r.ptr <= p && p < r.ptr + r.size)
                return r;
            r = r.prev;
        }
        return null;
    }
    
    size_t regionID(Region* r) {
        Region* rp = tail;
        size_t i;
        while (rp !is null) {
            if (rp == r)
                return i;
            i++;
            rp = rp.prev;
        }
        return size_t.max;
    }
    
    @property size_t numRegions() {
        size_t i;
        Region* r = tail;
        while (r !is null) {
            i++;
            r = r.prev;
        }
        return i;
    }
    
    //uses primary
    size_t extend(void* p, size_t minamt, size_t maxamt, bool* fail) {
        //fail is set if there is not enough room to extend
        //0 is returned if fail or p not in list
        Region* r = tail;
        while (r !is null) {
            if (r.ptr == p) {
                size_t cap = r.capacity - r.size;
                if (cap - KGC.GC_EXTRA_SIZE > minamt) {
                    size_t extamt = cap > maxamt ? maxamt : cap;
                    r.size += extamt;
                    return extamt;
                } else {
                    *fail = true;
                    return 0;
                }
            }
            r = r.prev;
        }
        return 0;
    }
    
    //uses primary
    void* regrab(void* p, size_t newsz, size_t* alloc_size = null, size_t* new_alloc_size = null) {
        Region* r = tail;
        while (r !is null) {
            if (r.ptr == p) {
                if (r.capacity >= newsz) {
                    if (new_alloc_size !is null)
                        *new_alloc_size = 0;
                    r.size = newsz;
                    if (alloc_size !is null)
                        *alloc_size += r.capacity;
                    return p;
                } else {
                    void* newp = grab(newsz, alloc_size);
                    if (new_alloc_size !is null)
                        *new_alloc_size = *alloc_size - r.capacity;
                    slib.memcpy(newp, p, r.size);
                    if (new_alloc_size !is null)
                    r.size = 0; //release r
                    
                    return newp;
                }
            }
            r = r.prev;
        }
        return null;
    }
    
    void updateConnections() {
        Region* r = tail;
        size_t found;
        while (r !is null) {
            if (r.color != _gc.epoch % 3) {
                
                
            }
            r = r.prev;
        }
        
    }
    
    void print() {
        if (tail == null) printf("(nil)\n");
        Region* r = tail;
        ulong i;
        ubyte white_color = _gc.epoch % 3;
        ubyte grey_color = (_gc.epoch-1) % 3;
        while (r !is null) {
            if (pm.query(r.ptr) !is null)
                printf("| %lu - %p - %lu bytes of %lu (%c) [M]\n",i,r,
                        (r.size == 0) ? 0 : r.size+_gc.GC_EXTRA_SIZE, r.capacity,
                        (r.size == 0 || r.fake_free) ? '-' : ((r.color == white_color) ? 'W' :
                        ((r.color == grey_color) ? 'G' : 'B'))
                    );
            else
                printf("| %lu - %p - %lu bytes of %lu (%c)\n",i,r,
                        (r.size == 0) ? 0 : r.size+_gc.GC_EXTRA_SIZE, r.capacity,
                        (r.size == 0 || r.fake_free) ? '-' : ((r.color == white_color) ? 'W' :
                        ((r.color == grey_color) ? 'G' : 'B'))
                    );
            r = r.prev;
            i++;
        }
    }
}

unittest {
    printf("---Freelist unittest---\n");
    Freelist fl;
    PointerMap cache;
    fl.initialize(0, &cache);
    gcAssert(fl.length == 0);
    void* p1 = fl.grab(10);
    void* p2 = fl.grab(8);
    gcAssert(fl.length == 2);
    gcAssert(fl.addrOf(p1+1) == p1);
    gcAssert(fl.regionOf(p1).ptr == p1);
    gcAssert(fl.release(p1));
    gcAssert(fl.length == 2);
    gcAssert(fl.minimize() == 10+KGC.GC_EXTRA_SIZE);
    gcAssert(fl.length == 1);
    fl.freeAll();
    gcAssert(fl.length == 0);
    printf("---end unittest---\n");
}

//used to match pointers to regions
//this is a first-pass check for marking
//if this fails, the region list is exhaustively scanned
//this is only a cache
struct PointerMap {
    Freelist.Region*[256] map;
    
    struct RegionList {
        Freelist.Region* ptr;
        RegionList* next;
    }
    
    ubyte hash(void* p) {
        return (cast(size_t)p >> 5) & 0xFF;
    }
    
    void add(void* p, Freelist.Region* rp) {
        map[hash(p)] = rp;
    }
    Freelist.Region* query(void* p) {
        ubyte h = hash(p);
        if (map[h] is null) return null;
        if (map[h].ptr != p) return null;
        return map[h];
    }
}
