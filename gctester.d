import std.c.stdio;
import gc.proxy;
//import gc.misc : onGCFatalError;
//import std.stdio;
//import std.conv;

//import std.stdio;

void main() {
    auto tc = new TestClass;
    gc_addRoot(cast(void*)tc);
    gc_collect();
    gc_wait(true);
    gc_dump();
}


class TestClass {
    int x, y;
    this() {
        printf(">>>CTOR<<<\n");
    }
    ~this() {
        printf(">>>DTOR<<<\n");
    }
}

