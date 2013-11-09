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
    if (marker.status == LaunchStatus.STOPPED) {
        marker.join();
    }
    if (marker.status == LaunchStatus.READY || marker.status == LaunchStatus.JOINED) {
        marker.launch();
    }
    if (sweeper.status == LaunchStatus.STOPPED) {
        sweeper.join();
    }
    if (sweeper.status == LaunchStatus.READY || sweeper.status == LaunchStatus.JOINED) {
        sweeper.launch();
    }
    
}

bool workersLaunched() {
    return (sweeper.status != LaunchStatus.READY &&
            sweeper.status != LaunchStatus.JOINED &&
            marker.status != LaunchStatus.READY &&
            marker.status != LaunchStatus.JOINED);
}

/*
void stop_workers() {
    if (marker.running && marker.handler)
        marker.sigUser2();
    if (sweeper.running && marer.handler)
        sweeper.sigUser2();
}
*/

void join_workers() {
    marker.join();
    sweeper.join();
}

void wake_workers() {
    marker.wake();
    sweeper.wake();
}

void marker_fn(GCT myThread) {
    scope (exit) printf("marker exit\n");
    
    while (true) {
        
        /*
         *  Wait
         */
        
        myThread.suspend(() { return !(_gc.collectInProgress == CollectMode.OFF); });
        _gc.collectInProgress = CollectMode.ON; //ensure CONTINUE is changed to ON
        
        /*
         *  Main
         */
        
        
        
        //first phase is copy
        //Markers part in this is to copy the stack/static data
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
        
        if (_gc.epoch < 253) _gc.epoch++;
        else _gc.epoch = 2;
        
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

void sweeper_fn(GCT myThread) {
    scope (exit) printf("sweeper exit\n");
    
    while (true) {
        
        /*
         *  Wait
         */
        
        myThread.suspend(() { return !(_gc.collectInProgress == CollectMode.OFF); });
        
        /*
         *  Main
         */
         
        //first phase is copy
        //Sweepers part in this is:
        //snapshot primaryFL
        //copy roots (miscRootsQueue)
        //copy ranges
        
        _gc.primaryFL.snapshot(_gc.secondaryFL);
        if (_gc.miscRootQueue.dirty) {
            //_gc.
        }
        
        printf("S:(sweep)\n");
        //do
         
        //signal to marker
        sweepCopyDone = true;
         
        //now it's time to do the actual sweep
        
        size_t release_size = 0;
        
        //first things first, process the requests in freeQueue
        //since the free queue can only be appended to by the mutator
        //we don't need to make a copy (fingers crossed)
        
        //the whole point of having a free queue is so that
        //we don't double-free a pointer out from under the sweeper
        //by calling gc_free on it
        
        {
            _gc.freeQueueLock.lock();
            scope (exit) _gc.freeQueueLock.unlock();
            
            _gc.freeQueue.release(&release_size);
        }
        
        //then go through secondaryFL and merge changes
        _gc.secondaryFL.freeSweep(&release_size);
        
        _gc.bytesReleased += release_size;
        
         
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

/*
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
*/
