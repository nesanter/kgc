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
 * Or any other thing to allow it to be garbage collected
 */
 
debug = USAGE;

enum LaunchStatus { READY, LAUNCHING, RUNNING, STOPPED, JOINED }

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
    
    static extern (C) void cleanup_handler(void* arg) nothrow {
        GCT obj = cast(GCT)arg;
        if (obj !is null)
            obj.status = LaunchStatus.STOPPED;
        else
            printf("obj was null");
        debug (USAGE) printf("<GCT> cleanup handler\n");
    }
    
    pthread_cleanup cleanup = void;
    cleanup.push(&cleanup_handler, cast(void*)obj);
    
    obj.status = LaunchStatus.RUNNING;
    
    //setup for suspending via .suspend()
    sigfillset(&obj.suspendSet);
    sigdelset(&obj.suspendSet, SIGUSR1);
    
    obj.run(obj);
    
    cleanup.pop(1);
    
    debug (USAGE) printf("<GCT> end entrypoint\n");
    
    return null;
}

final class GCT {
    LaunchStatus status = LaunchStatus.READY;
    bool suspended;
    private pthread_t addr;
    const(char*) name;
    private void function(GCT) run;
    private sigset_t suspendSet, oldSet;
    
    this(const(char*) n, void function(GCT) fn) {
        run = fn;
        name = n;
    }
    
    void launch() {
        debug (USAGE) {
            printf("<GCT> launch: ");
            printf(name);
            printf("\n");
        }
        
        version (assert) {
            gcAssert(status == LaunchStatus.READY || status == LaunchStatus.JOINED);
        }
        scope (failure) printf("<GCT> launch failure\n");
        
        pthread_attr_t attr;
        if (pthread_attr_init(&attr))
            onGCFatalError();
        if (pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_JOINABLE))
            onGCFatalError();
        
        if (pthread_create(&addr, &attr, &gct_entrypoint, cast(void*)this))
            onGCFatalError();
        
        status = LaunchStatus.LAUNCHING;
    }
    void join() {
        debug (USAGE) {
            printf("<GCT> join: ");
            printf(name);
            printf("\n");
        }
        scope (failure) printf("<GCT> join failure");
        
        if (status == LaunchStatus.JOINED)
            onGCFatalError();
        
        while (status == LaunchStatus.LAUNCHING) {}
        if (status == LaunchStatus.RUNNING)
            cancel();
        
        if (pthread_join(addr, null))
            onGCFatalError();
        
        status = LaunchStatus.JOINED;
    }
    
    void abort() {
        if (pthread_equal(pthread_self(), addr)) {
            pthread_exit(null);
        } else {
            printf("<GCT> cannot abort non-self");
            onGCFatalError();
        }
    }
    
    void wake() {
        debug (USAGE) printf("<GCT> waking\n"); 
        kill(SIGUSR1);
    }
    
    void kill(int sig) {
        
        pthread_kill(addr, sig);
    }
    
    void cancel() {
        if (pthread_equal(pthread_self(), addr)) {
            printf("<GCT> cannot cancel self");
            onGCFatalError();
        } else
            pthread_cancel(addr);
    }
    
    void suspend(bool delegate() dg) {
        sigprocmask(SIG_BLOCK, &suspendSet, &oldSet);
        suspended = true;
        while (!dg()) {
            sigsuspend(&suspendSet);
        }
        suspended = false;
        sigprocmask(SIG_UNBLOCK, &suspendSet, null);
    }
}

void yield() {
    sched_yield();
}

version (unittest) {
    __gshared bool testflag = false;
}

unittest {
    printf("---GCT unittest---\n");
    static void dummyfn(GCT myThread) {
        printf("DUMMY\n");
        myThread.suspend(() { return testflag; });
    }
    
    GCT dummy;
    byte[__traits(classInstanceSize, GCT)] dummyStorage;
    dummyStorage[] = GCT.classinfo.init[];
    dummy = cast(GCT)dummyStorage.ptr;
    
    dummy.__ctor("dummy",&dummyfn);
    
    dummy.launch();
    while (!dummy.suspended) {}
    testflag = true;
    dummy.wake();
    dummy.join();
    
    gcAssert(testflag);
    
    printf("---end unittest---\n");
}
