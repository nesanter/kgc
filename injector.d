module gc.injector;

//debug = USAGE;

import core.stdc.stdio;
import core.stdc.stdlib;
import core.stdc.string;

import gc.grapher;
import gc.marking;
import gc.proxy;

__gshared bool KEEP_INJECTING;
__gshared bool HEAP_SCAN_ON;

alias void* injector_payload_t;
immutable size_t injector_alloc_num = 2;

struct InjectorData {
    void* return_ptr;
    void** barrier;
    injector_payload_t* payload;
    size_t npayloads, psz;
    InjectorData* prev;
}

//All of these should be thread-local
// (fibers will be delt with later)
private InjectorData* injector_head;
package void** injector_backprop_barrier;

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

extern (C) void inject_outer_2(injector_payload_t payload, void* prevptr) {
    asm {
        naked;
        mov RDX, RBP;
        mov RDX, [RDX];
        mov RDX, [RDX];
        add RDX, 0x8;
        call inject_set_payload_2;
        ret;
    }
}

extern (C) void injected_fn() {
    asm {
        naked;
        sub RSP, 0x10;
        mov [RSP-0x8], RAX;
        mov RDI, RSP;
        add RDI, 0x8;
        mov [RSP], RBP;
        mov RBP, RSP;
        sub RSP, 0x8;
        call inject_restore;
        mov RAX, [RBP-0x8];
        leave;
        ret;
    }
}

extern (C) void inject_set_payload(injector_payload_t payload, void** target) {
    //if (!INJECTOR_ON) return;
    debug (USAGE) printf("Injecting into %p @ %p\n",*target,target);
    
    if (HEAP_SCAN_ON) {
        void** potential_roots;
        //start scanning at target
        //and move up 2 frames (to beginning of function that called target)
        size_t nroots = injector_scan(&potential_roots, target, 2);
    }
    
    size_t n;
    if (*target == &injected_fn) {
        //already injected
        if (injector_head.npayloads == injector_head.psz) {
            injector_head.payload = cast(injector_payload_t*)realloc(injector_head.payload, (injector_head.psz + injector_alloc_num) * injector_payload_t.sizeof);
            injector_head.psz += injector_alloc_num;
        }
        injector_head.payload[injector_head.npayloads++] = payload;
        n = graph_add_or_get(NodeType.FN, injector_head.return_ptr);
    } else {
        //create new data
        InjectorData* tmp = cast(InjectorData*)malloc(InjectorData.sizeof);
        if (tmp is null)
            abort();
        injector_payload_t* p = cast(injector_payload_t*)malloc(injector_payload_t.sizeof * injector_alloc_num);
        p[0] = payload;
        *tmp = InjectorData(*target, target, p, 1, injector_alloc_num, injector_head);
        injector_head = tmp;
        //install injected_fn
        n = graph_add_or_get(NodeType.FN, *target);
        *target = &injected_fn;
    }
    graph_add_child(NodeType.HEAP, payload, n);
}

//used to backpropogate
extern (C) void inject_set_payload_2(injector_payload_t payload, void* prevptr, void** target) {
    debug (USAGE) printf("Propogating into %p @ %p\n",*target,target);
    
    if (HEAP_SCAN_ON) {
        void** potential_roots;
        size_t nroots = injector_scan(&potential_roots, target, 2);
    }
    
    size_t n;
    if (*target == &injected_fn) {
        //already injected
        if (injector_head.prev.npayloads == injector_head.prev.psz) {
            injector_head.prev.payload = cast(injector_payload_t*)realloc(injector_head.prev.payload, (injector_head.prev.psz + injector_alloc_num) * injector_payload_t.sizeof);
            injector_head.prev.psz += injector_alloc_num;
        }
        injector_head.prev.payload[injector_head.prev.npayloads++] = payload;
        n = graph_add_or_get(NodeType.FN, injector_head.prev.return_ptr);
    } else {
        //create new data (insert behind current)
        InjectorData* tmp = cast(InjectorData*)malloc(InjectorData.sizeof);
        if (tmp is null)
            abort();
        injector_payload_t* p = cast(injector_payload_t*)malloc(injector_payload_t.sizeof * injector_alloc_num);
        p[0] = payload;
        *tmp = InjectorData(*target,target, p, 1, injector_alloc_num, injector_head.prev);
        injector_head.prev = tmp;
        //install injected_fn
        n = graph_add_or_get(NodeType.FN, *target);
        *target = &injected_fn;
    }
    graph_add_connection(n, payload);
    size_t prevnode = graph_add_or_get(NodeType.FN, prevptr);
    graph_add_connection(n, prevptr);
}

extern (C) void inject_restore(void** target) {
    //uninstall injected_fn
    *target = injector_head.return_ptr;
    //print debug message
    debug (USAGE) printf("How'd a snrk get in %p @ %p?\n",injector_head.return_ptr,target);
    for (size_t i=0; i<injector_head.npayloads; ++i) {
        debug (USAGE) printf("%lu - %p\n",i,injector_head.payload[i]);
        if (KEEP_INJECTING) inject_outer_2(injector_head.payload[i], injector_head.return_ptr);
    }
    graph_disown(*target);
    free(injector_head.payload);
    InjectorData* prev = injector_head.prev;
    free(injector_head);
    //set head back
    injector_head = prev;
}

void** get_barrier() {
    return injector_head.barrier;
}

size_t injector_scan(void*** dest, void** target, size_t depth) {
    printf("target = %p\n",target,*target);
    void** start = target-8;
    for (int i=0; i<depth; ++i) {
        start = cast(void**)(*start);
    }
    printf("start = %p\n",start);
    *dest = cast(void**)malloc(target-start);
    int i = 0;
    for (void** ptr=start; ptr<target; ptr += (void*).sizeof) {
        if (potentialPointer(*ptr) && _gc.primaryFL.regionOf(*ptr) !is null)
            (*dest)[i++] = *ptr;
    }
    printf("%lu potential roots found\n",i);
    return i;
}
