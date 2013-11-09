module gc.t_main;

/* Threading facility for KGC
 * 
 * Uses pthreads
 * 
 */ 

import gc.misc : onGCFatalError, gcAssert;
import core.stdc.stdio;

version (Posix) { 
    version (OSX) {
        pragma(msg, "Not sure whether OSX is supported....?");
    }
}
else {
    static assert(0, "Unsupported OS");
}

import core.sys.posix.semaphore;
import core.sys.posix.stdlib;
import core.sys.posix.pthread;
import core.sys.posix.signal;
import core.sys.posix.time;

/* This does not create TLS for the thread
 * This does not set up a stack to be scanned
 * This does not set up suspend signal handlers
 * Or really do any nice, polite things
 */
 
debug = USAGE;

extern (C) void* gct_entrypoint(void* arg) {
    
    debug (USAGE) printf("<GCT> entrypoint\n");
    
    scope (failure) printf("<GCT> thread failure\n");
    
    GCT obj = cast(GCT)arg;
    version (assert) {
        if (obj is null) {
            printf("<GCT> error in entrypoint\n");
            pthread_exit(null);
        }
    }
    obj.running = true;
    
    scope (exit) {
        obj.running = false;
        printf("<GCT> no longer running\n");
    }
    
    static extern (C) void cleanup_handler(void* arg) nothrow {
        GCT obj = cast(GCT)arg;
        if (obj !is null)
            obj.running = false;
        else
            printf("obj was null");
        debug (USAGE) printf("<GCT> cleanup handler\n");
    }
    
    pthread_cleanup cleanup = void;
    cleanup.push(&cleanup_handler, cast(void*)obj);
    
    obj.run();
    
    cleanup.pop(0);
    
    debug (USAGE) printf("<GCT> end entrypoint\n");
    
    return null;
}

final class GCT {
    bool running, launched;
    pthread_t addr;
    const(char*) name;
    void function() run;
    
    this(const(char*) n, void function() fn) {
        run = fn;
        name = n;
    }
    
    void launch() {
        debug (USAGE) {
            printf("<GCT> launch: ");
            printf(name);
            printf("\n");
        }
        
        scope (failure) printf("<GCT> launch failure\n");
        
        pthread_attr_t attr;
        if (pthread_attr_init(&attr))
            onGCFatalError();
        if (pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_JOINABLE))
            onGCFatalError();
        
        if (pthread_create(&addr, &attr, &gct_entrypoint, cast(void*)this))
            onGCFatalError();
        
        launched = true;
    }
    void join() {
        debug (USAGE) {
            printf("<GCT> join: ");
            printf(name);
            printf("\n");
        }
        scope (failure) printf("<GCT> join failure");
        
        if (pthread_join(addr, null))
            onGCFatalError();
        
        launched = false;
    }
    
    void abort() {
        if (pthread_equal(pthread_self(), addr)) {
            pthread_exit(null);
        } else {
            printf("<GCT> cannot abbort non-self");
            onGCFatalError();
        }
    }
    
    void sigUser1() {
        kill(SIGUSR1);
    }
    
    void sigUser2() {
        kill(SIGUSR2);
    }
    
    void kill(int sig) {
        pthread_kill(addr, sig);
    }
}

version (unittest) {
    __gshared bool testflag = false;
}

unittest {
    printf("---GCT unittest---\n");
    static void dummyfn() {
        testflag = true;
    }
    
    GCT dummy;
    byte[__traits(classInstanceSize, GCT)] dummyStorage;
    dummyStorage[] = GCT.classinfo.init[];
    dummy = cast(GCT)dummyStorage.ptr;
    
    dummy.__ctor("dummy",&dummyfn);
    
    dummy.launch();
    dummy.join();
    
    gcAssert(testflag);
    
    printf("---end unittest---\n");
}
