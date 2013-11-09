import std.c.stdio;
import gc.proxy;
//import gc.misc : onGCFatalError;
//import std.stdio;
//import std.conv;

//import std.stdio;

void main() {
    auto tc = new TestClass;
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

