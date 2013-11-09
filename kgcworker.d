module gc.t_marker;

import gc.proxy;
import gc.misc : onGCFatalError;
import gc.t_main;
import core.stdc.stdio;
import core.stdc.stdlib;

import core.sys.posix.pthread : pthread_exit, sched_yield;
import core.sys.posix.signal;

__gshared GCT marker;
__gshared byte[__traits(classInstanceSize, GCT)] markerStorage;
__gshared GCT sweeper;
__gshared byte[__traits(classInstanceSize, GCT)] sweeperStorage;

private __gshared bool sweepFinished, sweepCopyDone;

enum CollectMode {
    OFF, ON, CONTINUE
}

immutable bool workerStayAlive = false;

void init_workers() {
    markerStorage[] = GCT.classinfo.init[];
    marker = cast(GCT)markerStorage.ptr;
    marker.__ctor("marker", &marker_fn);
    sweeperStorage[] = GCT.classinfo.init[];
    sweeper = cast(GCT)sweeperStorage.ptr;
    sweeper.__ctor("sweeper", &sweeper_fn);
}

//should only be called when the GC is locked
void launch_workers(ref bool mlaunched, ref bool slaunched) {
    if (!sweeper.running) {
        if (sweeper.launched)
            sweeper.join();
        sweeper.launch();
    }
    if (!marker.running) {
        if (marker.launched)
            marker.join();
        marker.launch();
    }
}

bool workersLaunched() {
    return (sweeper.launched && marker.launched);
}

void stop_workers() {
    if (marker.running)
        marker.sigUser2();
    if (sweeper.running)
        sweeper.sigUser2();
}

void join_workers() {
    if (marker.launched)
        marker.join();
    if (sweeper.launched)
        sweeper.join();
}

void wake_workers() {
    marker.sigUser1();
    sweeper.sigUser1();
}

void marker_fn() {
    //Respond to signal
    signal(SIGUSR2, &marker_handler);
    
    sigset_t suspendSet, oldSet;
    sigemptyset(&suspendSet);
    sigaddset(&suspendSet, SIGUSR1);
    
    scope (exit) printf("marker exit\n");
    
    while (true) {
        
        /*
         *  Wait
         */
        
        sigprocmask(SIG_BLOCK, &suspendSet, &oldSet);
        while (_gc.collectInProgress == CollectMode.OFF) {
            sigsuspend(&oldSet);
        }
        sigprocmask(SIG_UNBLOCK, &suspendSet, null);
        
        _gc.collectInProgress = CollectMode.ON; //ensure CONTINUE is changed to ON
        
        /*
         *  Main
         */
        
        if (_gc.epoch < 253) _gc.epoch++;
        else _gc.epoch = 2;

        
        //first phase is copy
        //Markers part in this is to scan the stack
        //Sweeper will report sweepCopyDone when it's finished it's part
        
        printf("M:(scanning stack)\n");
        
        while (!sweepCopyDone) {
            sched_yield();
        }
        
        //now it's time to do marking
        
        printf("M:(marking)\n");
        
        /*
         *  Sync
         */
        
        while (!sweepFinished) {
            //wait for sweeper
            sched_yield();
        }
        sweepFinished = false;
        sweepCopyDone = false;
        
        printf("M:(sync complete)\n");
        
        if (_gc.collectStopThreshold()) {
            //need to keep collecting
            _gc.collectInProgress = CollectMode.CONTINUE;
        } else {
            _gc.collectInProgress = CollectMode.OFF;
            if (!workerStayAlive)
                return;
        }    
    }
}

void sweeper_fn() {
    signal(SIGUSR2, &sweeper_handler);
    
    sigset_t suspendSet, oldSet;
    sigemptyset(&suspendSet);
    sigaddset(&suspendSet, SIGUSR1);
    
    scope (exit) printf("sweeper exit\n");
    
    while (true) {
        
        /*
         *  Wait
         */
        
        sigprocmask(SIG_BLOCK, &suspendSet, &oldSet);
        while (_gc.collectInProgress == CollectMode.OFF) {
            sigsuspend(&oldSet);
        }
        sigprocmask(SIG_UNBLOCK, &suspendSet, null);
        
        /*
         *  Main
         */
         
        //first phase is copy
        //Sweepers part in this is:
        //snapshot primaryFL
        //copy roots (miscRootsQueue)
        //copy ranges
        
        _gc.primaryFL.snapshot(_gc.secondaryFL);
        
        printf("S:(sweep)\n");
        //do
         
        //signal to marker
        sweepCopyDone = true;
         
        //now it's time to do the actual sweep
        
        //first things first, process the requests in freeQueue
        
        //then go through secondaryFL
        size_t release_size;
        _gc.secondaryFL.freeSweep(&release_size);
        
        //finally, merge changes
         
        /*
         *  Sync
         */
        
        sweepFinished = true;
        
        if (!workerStayAlive)
            if (!_gc.collectStopThreshold())
                return;
        while (_gc.collectInProgress == CollectMode.ON) {
            //wait for marker
            sched_yield();
        }
        
    }
}

extern (C) void marker_handler(int sig) nothrow {
    if (sig == SIGUSR2) {
        printf("SIGUSR2 RECEIVED\n");
        printf("(cleanup marker)\n");
        pthread_exit(null);
    } else {
        printf("Unknown signal received\n");
    }
}

extern (C) void sweeper_handler(int sig) nothrow {
    if (sig == SIGUSR2) {
        printf("SIGUSR2 RECEIVED\n");
        printf("(cleanup sweeper)\n");
        pthread_exit(null);
    } else {
        printf("Unknown signal received\n");
    }
}
