module gc.util.injector;

//debug = USAGE;
//version = GCOUT;
//version = TRACK_DEAD_FN;
//version = TRACK_FN_CONS;
//debug = GC_PROFILE;

import core.stdc.stdio;
import clib = core.stdc.stdlib;
import slib = core.stdc.string;
debug (GC_PROFILE) import core.stdc.time;

import gc.util.grapher;
import gc.util.marking;
import gc.proxy;
import gc.util.freelists;

__gshared bool KEEP_INJECTING;
__gshared bool HEAP_SCAN_ON;
__gshared void** BACKSCAN_MAX;

alias Freelist.Region* injector_payload_t;
immutable size_t injector_alloc_num = 2;
version (GRAPH_FULL) size_t fnidnum;

struct InjectorData {
    void* return_ptr;
    Barrier barrier;
    injector_payload_t* payload;
    size_t npayloads, psz;
    InjectorData* prev;
    size_t counter;
    
    version (GCOUT) {
        version (GRAPH_FULL) {
            InjectorData* caller;
        }
        size_t id;
    }
}

struct Barrier {
    void** ptop;
    void** pbot;
    this(void** target) {
        pbot = cast(void**)(*(target-1));
        ptop = target;
        //printf("barrier: %p -> %p\n",pbot,ptop);
    }
}

//All of these should be thread-local
// (fibers will be delt with later)
public InjectorData* injector_head;
public InjectorData* injector_head_dead;

debug (GC_PROFILE) {
    clock_t injectTime;
    clock_t restoreTimeA;
    clock_t restoreTimeB;
    clock_t restoreTimeC;
    clock_t collectTime;
    clock_t verifyTime;
    clock_t updateTime;
    clock_t sweepTime;
    clock_t scangTime;
}

extern (C) void inject_outer(injector_payload_t payload) {
    asm {
        naked;
        mov RSI, RBP;
        mov RSI, [RSI];
        add RSI, 0x8;
        call inject_set_payload;
        ret;
    }
}

extern (C) void inject_outer_2(injector_payload_t* payload, size_t npayloads, InjectorData* prevptr) {
    asm {
        naked;
        mov RCX, RBP;
        mov RCX, [RCX];
        mov RCX, [RCX];
        add RCX, 0x8;
        call inject_set_payload_2;
        ret;
    }
}

extern (C) void injected_fn() {
    asm {
        naked;
        //make room for return ptr & base ptr
        sub RSP, 0x10;
        mov RDI, RSP;
        add RDI, 0x8; //target for return ptr
        mov [RSP], RBP;
        mov RBP, RSP; //enter frame
        sub RSP, 0x10;
        mov [RBP-0x8], RAX; //store return values
        mov [RBP-0x10], RDX; //(RDX may be used as a RV)
        mov RSI, RAX;
        //mov RDX, RDX is redundant
        call inject_restore;
        mov RAX, [RBP-0x8]; //restore return values
        mov RDX, [RBP-0x10];
        leave; //exit frame
        ret; //return now that rp has been set
    }
}

extern (C) void inject_set_payload(injector_payload_t payload, void** target) {
    debug (USAGE) printf("<INJ> injecting into %p @ %p\n",*target,target);
    
    debug (GC_PROFILE) {
        clock_t start, stop;
        start = clock();
    }
    
    size_t n;
    if (*target == &injected_fn) {
        //already injected
        if (injector_head.npayloads == injector_head.psz) {
            injector_head.payload = cast(injector_payload_t*)clib.realloc(injector_head.payload, (injector_head.psz + injector_alloc_num) * injector_payload_t.sizeof);
            injector_head.psz += injector_alloc_num;
        }
        injector_head.payload[injector_head.npayloads++] = payload;
        //n = graph_add_or_get(NodeType.FN, injector_head.return_ptr);
    } else {
        //create new data
        InjectorData* tmp = cast(InjectorData*)clib.malloc(InjectorData.sizeof);
        if (tmp is null)
            clib.abort();
        injector_payload_t* p = cast(injector_payload_t*)clib.malloc(injector_payload_t.sizeof * injector_alloc_num);
        p[0] = payload;
        version (GCOUT) {
            version (GRAPH_FULL) *tmp = InjectorData(*target, Barrier(target), p, 1, injector_alloc_num, injector_head, 0, null, fnidnum++);
            else *tmp = InjectorData(*target, Barrier(target), p, 1, injector_alloc_num, injector_head, 0, fnidnum++);
        }
        else *tmp = InjectorData(*target, Barrier(target), p, 1, injector_alloc_num, injector_head, 0);
        (*tmp).payload[0] = payload;
        injector_head = tmp;
        //install injected_fn
        //n = graph_add_or_get(NodeType.FN, *target);
        *target = &injected_fn;
    }
    
    injector_head.counter++;
    
    //graph_add_child(NodeType.HEAP, payload, n);
    //if (HEAP_SCAN_ON) {
        injector_payload_t* potential_roots;
        injector_payload_t* potential_globals;
        //start scanning at target
        //and move up 2 frames (to beginning of function that called target)
        size_t nroots = injector_scan(&potential_roots, 3, 2);
        size_t nglobs = injector_scan_globals(&potential_globals);
        for (int i=0; i<nroots; ++i) {
            potential_roots[i].addConnection(payload);
            payload.addConnection(potential_roots[i]);
        }
        for (int i=0; i<nglobs; ++i) {
            potential_globals[i].addConnection(payload);
            payload.addConnection(potential_globals[i]);
        }
    //}
    
    debug (GC_PROFILE) {
        stop = clock();
        injectTime += (stop-start);
    }
    
}

//used to backpropogate
extern (C) void inject_set_payload_2(injector_payload_t* payload, size_t npayloads, InjectorData* prevptr, void** target) {
    debug (USAGE) printf("<INJ> propogating into %p @ %p\n",*target,target);
    
    debug (GC_PROFILE) {
        clock_t start, stop;
        start = clock();
    }
    
    version (GRAPH_FULL) InjectorData* fnptr;
    if (*target == &injected_fn) {
        //already injected
        /*
        if (injector_head.prev.npayloads == injector_head.prev.psz) {
            injector_head.prev.payload = cast(injector_payload_t*)realloc(injector_head.prev.payload, (injector_head.prev.psz + injector_alloc_num) * injector_payload_t.sizeof);
            injector_head.prev.psz += injector_alloc_num;
        }
        injector_head.prev.payload[injector_head.prev.npayloads++] = payload;
        */
        if (injector_head.payload !is null)
            injector_head.prev.payload = cast(injector_payload_t*)clib.realloc(injector_head.prev.payload, (injector_head.prev.psz + npayloads) * injector_payload_t.sizeof);
        slib.memcpy(cast(void*)injector_head.prev.payload + injector_head.prev.npayloads * injector_payload_t.sizeof, payload, npayloads * injector_payload_t.sizeof);
        injector_head.prev.psz += npayloads;
        injector_head.prev.npayloads += npayloads;
        version (GRAPH_FULL) fnptr = injector_head.prev;
    } else {
        //create new data (insert behind current)
        InjectorData* tmp = cast(InjectorData*)clib.malloc(InjectorData.sizeof);
        version (GCOUT) {
            version (GRAPH_FULL) *tmp = InjectorData(*target, Barrier(target), payload, 1, injector_alloc_num, injector_head.prev, 0, null, fnidnum++);
            else *tmp = InjectorData(*target, Barrier(target), payload, 1, injector_alloc_num, injector_head.prev, 0, fnidnum++);
        }
        else *tmp = InjectorData(*target, Barrier(target), payload, 1, injector_alloc_num, injector_head.prev, 0);
        injector_head.prev = tmp;
        //install injected_fn
        version (GRAPH_FULL) fnptr = tmp;
        *target = &injected_fn;
    }
    
    for (size_t i=0; i<npayloads; ++i) {
        injector_head.prev.counter += npayloads;
    }
    
    version (GRAPH_FULL) prevptr.caller = fnptr;
    
    debug (GC_PROFILE) {
        stop = clock();
        injectTime += (stop-start);
    }
}

extern (C) void inject_restore(void** target, void* rv_ax, void* rv_dx) {
    //uninstall injected_fn
    *target = injector_head.return_ptr;
    
    //print debug message
    debug (USAGE) printf("<INJ> how'd a snrk get in %p @ %p?\n",injector_head.return_ptr,target);
    
    debug (GC_PROFILE) {
        clock_t start, stop;
        start = clock();
    }
    
    //debug (USAGE) printf("rv_ax = %p, rv_dx = %p\n",rv_ax,rv_dx);
    
    injector_payload_t[2] rvroots;
    if (potentialPointer(rv_ax))
        rvroots[0] = _gc.primaryFL.regionOf(rv_ax);
    if (potentialPointer(rv_dx))
        rvroots[1] = _gc.primaryFL.regionOf(rv_dx);
    
    injector_payload_t* potential_roots/*, potential_globs*/;
    size_t nroots;
    if (rvroots[0] is null || rvroots[1] is null)
        nroots = injector_scan(&potential_roots, 1, 2, rvroots.ptr, rv_ax, rv_dx);
    else
        nroots = injector_scan(&potential_roots, 1, 2);
    //size_t nglobs = injector_scan_globals(&potential_globs, rvroots.ptr, rv_ax, rv_dx);
    if (rvroots[0] is null || rvroots[1] is null) {
        injector_scan_rvs(rvroots.ptr, rv_ax, rv_dx);
    }
    
    debug (GC_PROFILE) {
        stop = clock();
        restoreTimeA += (stop-start);
        start = clock();
    }
    
    if (nroots > 0 || rvroots[0] !is null || rvroots[1] !is null) {
        
        /*
        injector_payload_t* new_payloads = cast(injector_payload_t*)clib.malloc((injector_head.npayloads +
            (rvroots[0] !is null ? 1 : 0) + (rvroots[1] !is null ? 1 : 0)) * injector_payload_t.sizeof);
        
        slib.memcpy(new_payloads, injector_head.payload, injector_head.npayloads * injector_payload_t.sizeof);
        
        if (rvroots[0] !is null) new_payloads[injector_head.npayloads] = rvroots[0];
        if (rvroots[1] !is null) new_payloads[injector_head.npayloads +
                                    (rvroots[0] !is null ? 1 : 0)] = rvroots[1];
        
        inject_outer_2(new_payloads, injector_head.npayloads +
            (rvroots[0] !is null ? 1 : 0) +
            (rvroots[1] !is null ? 1 : 0), injector_head);
        */
        injector_payload_t* new_payloads = cast(injector_payload_t*)clib.malloc((nroots +
            (rvroots[0] !is null ? 1 : 0) + (rvroots[1] !is null ? 1 : 0)) * injector_payload_t.sizeof);
        slib.memcpy(new_payloads, potential_roots, nroots * injector_payload_t.sizeof);
        
        if (rvroots[0] !is null) new_payloads[nroots] = rvroots[0];
        if (rvroots[1] !is null) new_payloads[nroots +
                                    (rvroots[0] !is null ? 1 : 0)] = rvroots[1];
        
        inject_outer_2(new_payloads, nroots + (rvroots[0] !is null ? 1 : 0) + (rvroots[1] !is null ? 1 : 0), injector_head);        
    }
    
    debug (GC_PROFILE) {
        stop = clock();
        restoreTimeB += (stop-start);
        start = clock();
    }
    
    for (size_t i=0; i<injector_head.npayloads; ++i) {
        for (size_t n=0; n<nroots; ++n) {
            injector_head.payload[i].addConnection(potential_roots[n]);
            potential_roots[n].addConnection(injector_head.payload[i]);
        }
        //for (size_t n=0; n<nglobs; ++n) {
        //    injector_head.payload[i].addConnection(potential_globs[n]);
        //    potential_globs[n].addConnection(injector_head.payload[i]);
        //}
    }
    
    if (potential_roots !is null) clib.free(potential_roots);
    //if (potential_globs !is null) free(potential_globs);
    
    //graph_disown(*target);
    version (GRAPH_FULL) {
        if (injector_head_dead is null) {
            injector_head_dead = injector_head;
            InjectorData* prev = injector_head.prev;
            injector_head = prev;
            injector_head_dead.prev = null;
        } else {
            InjectorData* prev = injector_head.prev;
            injector_head.prev = injector_head_dead;
            injector_head_dead = injector_head;
            injector_head = prev;
        }
    } else {
        clib.free(injector_head.payload);
        InjectorData* prev = injector_head.prev;
        clib.free(injector_head);
        //set head back
        injector_head = prev;
    }
    
    debug (GC_PROFILE) {
        stop = clock();
        restoreTimeC += (stop-start);
    }
    
    if (_gc.collectStartThreshold()) {
        _gc.fullCollect();
    }
    
}

size_t injector_scan(injector_payload_t** dest, size_t back, size_t depth, injector_payload_t* rvroots = null, void* rv_ax = null, void* rv_dx = null) {
    void** start, end;
    asm {
        mov start, RBP;
    }
    for (int i=0; i<back; ++i) {
        start = cast(void**)*start;
    }
    end = start;
    //printf("start = %p\n",start);
    for (int i=0; i<depth; ++i) {
        end = cast(void**)(*end);
    }
    //printf("end = %p\n",end);
    
    if (rvroots !is null) {
        if (rv_ax >= start && rv_ax < end) {
            rvroots[0] = _gc.primaryFL.regionOf(*cast(void**)rv_ax);
        }
        if (rv_dx >= start && rv_dx < end) {
            rvroots[1] = _gc.primaryFL.regionOf(*cast(void**)rv_dx);
        }
    }
    
    *dest = cast(injector_payload_t*)clib.malloc(end-start);
    int i = 0;
    for (void** ptr=start; ptr<end; ptr += (void*).sizeof) {
        if (potentialPointer(*ptr)) {
            injector_payload_t pp = _gc.primaryFL.regionOf(*ptr);
            if (pp !is null)
                (*dest)[i++] = pp;
        }
    }
    debug (USAGE) printf("%lu potential roots found\n",i);
    return i;
}

size_t injector_scan_globals(injector_payload_t** dest, injector_payload_t* rvroots = null, void* rv_ax = null, void* rv_dx = null) {
    
    debug (GC_PROFILE) {
        clock_t start, stop;
        start = clock();
    }
    size_t g = 0;
    
    void dg(void* pbot, void* ptop) {
        for (void** ptr=cast(void**)pbot; ptr<=ptop; ++ptr) {
            if (potentialPointer(*ptr)) {
                injector_payload_t pp = _gc.primaryFL.regionOf(*ptr);
                if (pp !is null) {
                    if (*dest is null) (*dest) = cast(injector_payload_t*)clib.malloc(injector_payload_t.sizeof);
                    else (*dest) = cast(injector_payload_t*)clib.realloc(*dest, (g+1) * injector_payload_t.sizeof);
                    (*dest)[g++] = pp;
                    //debug (USAGE) printf("global found: %p @ %p (%p)\n",*ptr,ptr,pp);
                }
            }
        }
    }
    
    for (int r=0; r<_gc.nranges; ++r) {
        dg(_gc.ranges[r].pbot, _gc.ranges[r].ptop);
    }
    
    debug (GC_PROFILE) {
        stop = clock();
        scangTime += (stop-start);
    }
    
    debug (USAGE) printf("%lu globals found (__gshared only)\n",g);
    
    //core.thread.scanTLS(&dg);
    
    debug (USAGE) printf("%lu globals found (TLS + __gshared)\n",g);
    return g;
}

void injector_scan_rvs(injector_payload_t* rvroots, void* rv_ax, void* rv_dx) {
    for (int r=0; r<_gc.nranges; ++r) {
        if (rv_ax >= _gc.ranges[r].pbot && rv_ax <= _gc.ranges[r].ptop) {
            rvroots[0] = _gc.primaryFL.regionOf(*cast(void**)rv_ax);
        }
        if (rv_dx >= _gc.ranges[r].pbot && rv_dx <= _gc.ranges[r].ptop) {
            rvroots[1] = _gc.primaryFL.regionOf(*cast(void**)rv_dx);
        }
    }
}

void set_backscan_max() {
    asm {
        mov BACKSCAN_MAX, RBP;
    }
}
