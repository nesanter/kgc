import std.c.stdio;
import gc.proxy;
//import gc.misc : onGCFatalError;
//import std.stdio;
//import std.conv;

//import std.stdio;

void main() {
    /*
    printf("---main---\n");
    gc_collect();
    int x;
    foreach (i; 0 .. 100000) x++;
    gc_collect();
    //onGCFatalError();
    printf("---end main---\n");
    */
    void* p = gc_malloc(100);
    gc_dump();
    gc_free(p);
    gc_collect();
    gc_wait();
    gc_dump();
}

/*
class TestClass {
    int x, y;
    this() {
        printf("ctor\n");
    }
    ~this() {
        printf("dtor\n");
    }
}
*/
