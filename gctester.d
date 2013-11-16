import std.c.stdio;
import gc.proxy;
import gc.grapher;
import gc.injector;
//import std.stdio;
//import gc.misc : onGCFatalError;
//import std.stdio;
//import std.conv;

//import std.stdio;

void main() {
    /*
    auto tc = new TestClass;
    gc_addRoot(cast(void*)tc);
    gc_collect();
    gc_wait(true);
    gc_dump();
    */
    /*
    void* p = gc_malloc(20);
    void* p2 = gc_malloc(3);
    printf("%lu\n",cast(ulong)p % 128);
    printf("%lu\n",cast(ulong)p2 % 128);
    printf("%lu\n",p.alignof);
    */
    HEAP_SCAN_ON = true;
    
    graph_add_fname();
    
    
    KEEP_INJECTING = true;
    GRAPHER_ENABLED = true;
    auto tc = new TestClass;
    graph_output_dot();
    test();
    graph_output_dot();
    KEEP_INJECTING = false;
    GRAPHER_ENABLED = false;
    tc.snrk();
}

void test() {
    graph_add_fname();
    auto tc = new TestClass;
    test1();
}
void test1() {
    graph_add_fname();
    auto tc = new TestClass;
    auto tc2 = new TestClass;
    test2();
}
void test2() {
    graph_add_fname();
    auto tc = new TestClass;
    graph_output_dot();
}


class TestClass {
    this() {
        graph_add_fname();
        printf(">>>CTOR<<<\n");
        auto tc2 = new TestClass2;
    }
    ~this() {
        printf(">>>DTOR<<<\n");
    }
    void snrk() {
        
    }
}

class TestClass2 {
    
}
