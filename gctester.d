import std.c.stdio;
import std.c.stdlib;
import gc.proxy;
import gc.grapher;
import gc.injector;
import gc.misc;
import gc.marking;
import gc.freelists;
//import std.stdio;
//import gc.misc : onGCFatalError;
//import std.stdio;
//import std.conv;

//import std.stdio;
//import std.conv;

__gshared TestLinkedList globalll;
__gshared TestClass gtc;

void main() {
    HEAP_SCAN_ON = true;
    set_backscan_max();    
    graph_add_fname();
    KEEP_INJECTING = true;
    
    //GRAPHER_ENABLED = true;
    
    //testarrecurse();
    //auto ll = test();
    //auto ll = new TestLinkedList(5);
    
    /*
    for (int i=0; i<10; ++i) {
        test();
        incrementEpoch();
        verifyRecursive(injector_head, &_gc.primaryFL);
        _gc.primaryFL.fakeSweep();
        if (i % 5 == 0)
            graph_output_dot(injector_head, &_gc.primaryFL, injector_head_dead);
    }
    */
    
    printf("%p to %p\n",_gc.ranges[0].pbot, _gc.ranges[0].ptop);
    
    auto s = testrecurse();
    //auto ll = test();
    
    //writeln(s);
    //incrementEpoch();
    //verifyRecursive(injector_head, &_gc.primaryFL);
    //_gc.primaryFL.fakeSweep();
    graph_output_dot(injector_head, &_gc.primaryFL, injector_head_dead);
    
    //graph_output_dot(true);
    //graph_output_dot(true);
    //graph_output_dot(true,true);
    KEEP_INJECTING = false;
    //GRAPHER_ENABLED = false;
    
    gc_dump();
    //printf("space = %lu\n",512 * Node.sizeof + 2 * Freelist.sizeof + 4 * PointerQueue.sizeof + PointerMap.sizeof + KGC.sizeof);
}

string testrecurse() {
    graph_add_fname();
    auto s = string_recursion(10);
    return s;
}

TestLinkedList test() {
    graph_add_fname();
    //auto tc = new TestClass;
    //test1();
    //for (int i=0; i<10; ++i)
    //    auto tc = new TestClass;
    //graph_output_dot();
    auto ll = new TestLinkedList(5);
    //graph_output_dot(true);
    return ll;
}
void test1() {
    graph_add_fname();
    //auto tc = new TestClass;
    //auto tc2 = new TestClass;
    test2();
    //tc.snrk();
}
void test2() {
    graph_add_fname();
    auto tc = new TestClass;
    auto tc2 = new TestClass;
    //graph_output_dot(true);
    //backtrace(1);
    gtc = tc;
}


class TestClass {
    //TestClass2 snrk;
    this() {
        graph_add_fname();
        printf(">>>CTOR<<<\n");
        //TestClass2 tc2;
        //for (int i=0; i<10; ++i)
        //    tc2 = new TestClass2;
        //snrk = tc2;
        //hello = to!string(this);
        //();
        //graph_output_dot();
    }
    ~this() {
        printf(">>>DTOR<<<\n");
    }
}

class TestClass2 {
    this() {
        graph_add_fname();
    }
}

void backtrace(size_t depth) {
    void** p;
    asm {
        mov p, RBP;
    }
    for (int i=0; i<depth; ++i) {
        printf("%d - %p\n",i,p);
        p = cast(void**)*p;
    }
}

class TestLinkedList {
    TestLinkedList next;
    this(size_t add) {
        graph_add_fname();
        //incrementEpoch();
        //verifyRecursive(injector_head, &_gc.primaryFL);
        //_gc.primaryFL.fakeSweep();
        //graph_output_dot(injector_head, &_gc.primaryFL, injector_head_dead);
        if (add > 1)
            next = new TestLinkedList(add-1);
        //globalll = this;
        //graph_output_dot();
    }
}

string string_recursion(size_t n) {
    if (n == 0) return "x";
    return "x"~string_recursion(n-1);
}

size_t[] array_recursion(size_t n) {
    graph_add_fname();
    //graph_output_dot(true);
    if (n == 0) return [];
    auto a = array_recursion(n-1) ~ n;
    //incrementEpoch();
    //verifyRecursive(injector_head, &_gc.primaryFL);
    //sweep(&_gc.primaryFL);
    graph_output_dot(injector_head, &_gc.primaryFL);
    return a;
}
