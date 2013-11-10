module gc.t_main;

debug = USAGE;

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

enum LaunchStatus { READY, LAUNCHING, RUNNING, STOPPED, JOINED }

extern (C) void* gct_entrypoint(void* arg) {
    
    GCT obj = cast(GCT)arg;
    version (assert) {
        if (obj is null) {
            printf("<GCT> null obj in entrypoint\n");
            pthread_exit(null);
        }
    }
    
    debug (USAGE) printf("<GCT> thread entry (%s)\n",obj.name);
    debug (USAGE) scope (success) printf("<GCT> thread exit (%s)\n",obj.name);
    scope (failure) printf("<GCT> thread failure (%s)\n",obj.name);
    
    static extern (C) void cleanup_handler(void* arg) nothrow {
        GCT obj = cast(GCT)arg;
        if (obj !is null) {
            obj.status = LaunchStatus.STOPPED;
            debug (USAGE) printf("<GCT> cleanup handler (%s)\n",obj.name);
        } else {
            debug (USAGE) printf("<GCT> cleanup handler (null)\n");
        }
        
    }
    
    pthread_cleanup cleanup = void;
    cleanup.push(&cleanup_handler, cast(void*)obj);

    //disable wake signal before we are RUNNING
    signal(SIGUSR1, &handle_wake);
        
    obj.status = LaunchStatus.RUNNING;
    
    //setup for suspending via .suspend()
    sigemptyset(&obj.suspendSet);
    sigaddset(&obj.suspendSet, SIGUSR1);
    
    obj.run(obj);
    
    cleanup.pop(1);
    
    return null;
}

extern (C) void handle_wake(int sig) nothrow {
    debug (USAGE) {
        if (sig == SIGUSR1)
            printf("<GCT> received wake request\n");
    }
}

final class GCT {
    LaunchStatus status = LaunchStatus.READY;
    bool suspended;
    private pthread_t addr;
    const(char*) name;
    private void function(GCT) run;
    private sigset_t suspendSet, oldSet;
    private size_t critical;
    
    this(const(char*) n, void function(GCT) fn) {
        run = fn;
        name = n;
    }
    
    void launch() {
        debug (USAGE) printf("<GCT> launch (%s)\n",name);
        
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
    void join(bool force=true) {        
        if (status == LaunchStatus.JOINED ||
            status == LaunchStatus.READY)
            return;
        
        debug (USAGE) printf("<GCT> join (%s)\n",name);
        scope (failure) printf("<GCT> join failure");

        
        while (status == LaunchStatus.LAUNCHING) {}
        if (force && status == LaunchStatus.RUNNING)
            cancel();
        
        if (pthread_join(addr, null))
            onGCFatalError();
        
        status = LaunchStatus.JOINED;
    }
    
    void abort() {
        debug (USAGE) printf("<GCT> abort (%s)",name);
        if (pthread_equal(pthread_self(), addr)) {
            pthread_exit(null);
        } else {
            printf("<GCT> cannot abort non-self");
            onGCFatalError();
        }
    }
    
    void wake() {
        debug (USAGE) printf("<GCT> waking (%s)\n",name); 
        if (status != LaunchStatus.RUNNING)
            return;
        version (assert) gcAssert(suspended);
        kill(SIGUSR1);
    }
    
    void kill(int sig) {
        pthread_kill(addr, sig);
    }
    
    void cancel() {
        debug (USAGE) printf("<GCT> cancel (%s)\n",name);
        if (pthread_equal(pthread_self(), addr)) {
            printf("<GCT> cannot cancel self");
            onGCFatalError();
        } else
            pthread_cancel(addr);
    }
    
    void suspend(bool delegate() dg) {
        debug (USAGE) printf("<GCT> suspend (%s)\n",name);
        sigprocmask(SIG_BLOCK, &suspendSet, &oldSet);
        suspended = true;
        while (dg()) {
            sigsuspend(&oldSet);
        }
        suspended = false;
        sigprocmask(SIG_UNBLOCK, &suspendSet, null);
    }
    
    void enter_critical_region() {
        debug (USAGE) printf("<GCT> enter critical region (%s)\n",name);
        critical++;
        int oldstate;
        if (critical == 1) pthread_setcancelstate(PTHREAD_CANCEL_DISABLE, &oldstate);
    }
    
    void exit_critical_region() {
        debug (USAGE) printf("<GCT> exit critical region (%s)\n",name);
        critical--;
        int oldstate;
        if (critical == 0) pthread_setcancelstate(PTHREAD_CANCEL_ENABLE, &oldstate);
    }
}

void yield() {
    sched_yield();
}

struct Condition {
    pthread_cond_t condition;
    pthread_mutex_t mutex;
    void initialize() {
        pthread_cond_init(&condition, null);
    }
    void wait() {
        pthread_mutex_lock(&mutex);
        pthread_cond_wait(&condition, &mutex);
        pthread_mutex_unlock(&mutex);
    }
    void notify() {
        pthread_mutex_lock(&mutex);
        pthread_cond_broadcast(&condition);
        pthread_mutex_unlock(&mutex);
    }
}

version (unittest) {
    __gshared int testflag = 0;
}

unittest {
    printf("---GCT unittest---\n");
    static void dummyfn(GCT myThread) {
        myThread.suspend(() { return testflag++ == 0; });
    }
    
    GCT dummy;
    byte[__traits(classInstanceSize, GCT)] dummyStorage;
    dummyStorage[] = GCT.classinfo.init[];
    dummy = cast(GCT)dummyStorage.ptr;
    
    dummy.__ctor("dummy\0",&dummyfn);
    
    dummy.launch();
    while (!dummy.suspended) {}
    dummy.wake();
    dummy.join(false);
    
    gcAssert(testflag == 2);
    
    printf("---end unittest---\n");
}
