import std.c.stdio;
import gc.proxy;
//import gc.misc : onGCFatalError;
//import std.stdio;
//import std.conv;

//import std.stdio;

void main() {
    auto tc = new TestClass;
    void* p = gc_malloc(100);
    gc_dump();
    gc_collect();
    gc_wait();
}


class TestClass {
    int x, y;
    this() {
        printf("ctor\n");
    }
    ~this() {
        printf("dtor\n");
    }
}

