module gc.t_marker;

//debug = VERBOSE;

import gc.proxy;
import gc.misc : onGCFatalError, Range, PointerQueue;
import gc.t_main;
import gc.marking;
import core.stdc.stdio;
import clib = core.stdc.stdlib;
import slib = core.stdc.string : memcpy;

import core.sys.posix.pthread : pthread_exit, sched_yield;
import core.sys.posix.signal;
import core.thread;

__gshared GCT marker;
__gshared byte[__traits(classInstanceSize, GCT)] markerStorage;
__gshared GCT sweeper;
__gshared byte[__traits(classInstanceSize, GCT)] sweeperStorage;

__gshared bool sweepCopyDone, sweepFinished, scanFinished, boundsUpdated;
__gshared Condition syncCondition1, syncCondition2,
                    syncCondition3, syncCondition4,
                    syncCondition5;

enum CollectMode {
    OFF, ON, CONTINUE
}

immutable bool workerStayAlive = false;

void init_workers() {
    markerStorage[] = GCT.classinfo.init[];
    marker = cast(GCT)markerStorage.ptr;
    marker.__ctor("marker\0", &marker_fn);
    sweeperStorage[] = GCT.classinfo.init[];
    sweeper = cast(GCT)sweeperStorage.ptr;
    sweeper.__ctor("sweeper\0", &sweeper_fn);
    syncCondition1.initialize();
    syncCondition2.initialize();
    syncCondition3.initialize();
    syncCondition4.initialize();
}

//should only be called when the GC is locked
void launch_workers() {
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

bool workersActive() {
    return (sweeper.status == LaunchStatus.LAUNCHING ||
            sweeper.status == LaunchStatus.RUNNING) &&
            (marker.status == LaunchStatus.LAUNCHING ||
            marker.status == LaunchStatus.RUNNING);
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
    debug (VERBOSE) scope (exit) printf("<M> exit\n");
    
    while (true) {
        
        /*
         *  Wait
         */
        
        myThread.suspend(() { return (_gc.collectInProgress == CollectMode.OFF); });
        
        _gc.progressLock.acquire();

        //this isn't needed: (it's now the sweeper's job)
        //_gc.collectInProgress = CollectMode.ON; //ensure CONTINUE is changed to ON
        
        
        /*
         *  Main
         */
        
        //first phase is copy
        //Markers part in this is to copy the stack/static data
        //Sweeper will report sweepCopyDone when it's finished it's part
        
        debug (VERBOSE) printf("<M> scanning stack\n");
        
        //for each thread:
        //   scanForPointers(stackptr, stacksz) --> add to rootSet
        
        
        
        
        
        while (!sweepCopyDone) {
            syncCondition1.wait();
        }
        
        //now it's time to do marking of previous snapshot
        
        debug (VERBOSE) printf("<M> marking\n");
        
        _gc.miscRootQueueCopy.iter!false((ref ptr) { markRecursive(ptr); return 0;});
        PointerQueue rangeptrs;
        for (size_t i=0; i<_gc.nrangesCopy; ++i) {
            printf("range num: %d\n",i);
            scanForPointers(_gc.rangesCopy[i].pbot,
                    _gc.rangesCopy[i].ptop-_gc.rangesCopy[i].pbot,
                    &rangeptrs
                );
            rangeptrs.iterDequeue((ptr) { markRecursive(ptr); });
        }
        
        //wait for the scanner to inform us of stack bounds
        
        while (!boundsUpdated) {
            syncCondition4.wait();
        }
        
        //This goes through the previously gathered root set
        _gc.rootSetA.iter!true((ref ptr) { markRecursive(ptr); return 0;});
        
        //now we wait for the scanner
        
        while (!scanFinished) {
            syncCondition5.wait();
        }
        
        //now we can go through the new root set
        //this will repeat some, but those regions will have already
        //been colored and thus will not be expensively explored
        _gc.rootSetB.iter!true((ref ptr) { markRecursive(ptr); return 0;});
        
        //and now flip
        _gc.rootSetA = _gc.rootSetB;
        _gc.rootSetB.clear();
        
        /*
         *  Sync
         */
        
        while (!sweepFinished) {
            //wait for sweeper
            syncCondition2.wait();
        }
        sweepFinished = false;
        sweepCopyDone = false;
        boundsUpdated = false;
        scanFinished = false;
        
        debug (VERBOSE) printf("<M> sync complete\n");
        
        //safe to change epoch
        //b/c it will occur atomically & we are the only one allowed to
        if (_gc.epoch < 253) _gc.epoch++;
        else _gc.epoch = 2;
        
        {
            scope (exit) {
                _gc.progressLock.transfer();
                syncCondition3.notify();
            }
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
}

void sweeper_fn(GCT myThread) {
    debug (VERBOSE) scope (exit) printf("<S> exit\n");
    
    while (true) {
        
        /*
         *  Wait
         */
        
        myThread.suspend(() { return (_gc.collectInProgress == CollectMode.OFF); });
        
        /*
         *  Main
         */
         
        //first phase is copy
        //Sweepers part in this is:
        //snapshot primaryFL
        //copy roots (miscRootsQueue)
        //copy ranges
        
        {
            myThread.enter_critical_region();
            scope (exit) myThread.exit_critical_region();
            _gc.mutatorLock.lock();
            scope (exit) _gc.mutatorLock.unlock();
        
            _gc.primaryFL.snapshot(&_gc.secondaryFL);
            _gc.miscRootQueue.copy(&_gc.miscRootQueueCopy);
            printf("miscrootqueuecopy:\n");
            _gc.miscRootQueueCopy.print!true("miscRootQueueCopy");
            
            if (_gc.rangesDirty) {
                if (_gc.rangesCopy !is null)
                    clib.free(_gc.rangesCopy);
                _gc.rangesCopy = cast(Range*)clib.malloc(_gc.nranges * Range.sizeof);
                slib.memcpy(_gc.rangesCopy, _gc.ranges, _gc.nranges * Range.sizeof);
                _gc.nrangesCopy = _gc.nranges;
            }
        }

        //signal to marker            
        sweepCopyDone = true;
        syncCondition1.notify();
        
        //now it's time to do the actual sweep
        
        size_t release_size = 0;
        
        //first things first, process the requests in freeQueue
        //since the free queue can only be appended to by the mutator
        //we don't need to make a copy (fingers crossed)
        
        //the whole point of having a free queue is so that
        //we don't double-free a pointer out from under the sweeper
        //by calling gc_free on it
        
        {
            myThread.enter_critical_region();
            scope (exit) myThread.exit_critical_region();
            
            _gc.freeQueueLock.lock();
            scope (exit) _gc.freeQueueLock.unlock();
            
            _gc.freeQueue.release(&release_size);
        }
        
        //then go through secondaryFL and merge changes
        _gc.secondaryFL.freeSweep(&release_size);
        
        debug (VERBOSE) printf("<S> released %llu bytes\n",release_size);
        _gc.bytesReleased += release_size;
         
        /*
         *  Sync
         */
        
        sweepFinished = true;
        syncCondition2.notify();
        
        while (!_gc.progressLock.acquire2()) { syncCondition3.wait(); }
        
        debug (VERBOSE) printf("<S> sync complete\n");
        
        {
            scope (exit) _gc.progressLock.release();
            if (_gc.collectInProgress == CollectMode.CONTINUE) {
                _gc.collectInProgress = CollectMode.ON;
            } else {
                if (!workerStayAlive)
                    return;
            }        
        }
    }
}

/*  The Scanner is responsible for creating a snapshot
 *  of potential pointers in the stack
 */ 
void scanner_fn(GCT myThread) {
    debug (VERBOSE) scope (exit) printf("<X> exit\n");
    
    /*
     *  Wait
     */
     
    myThread.suspend(() { return (_gc.collectInProgress == CollectMode.OFF); });
    
    /*
     * Scan
     */
     
    //first we need to establish the stack size of each thread
    //before the marker can go forward with phase 1
    
    
    //suspend all threads
    //for each thread:
    //  get stack min/max
    //set mins/maxes -> rootBounds
    
    //notify marker he may proceed
    boundsUpdated = true;
    syncCondition4.notify();
    
    
    //for each thread:
    //  scanForPointers(thread.stacktop, thread.stacksz, &rootSetB);
    //wake all threads
    
    thread_resumeAll();
    
    scanFinished = true;
    syncCondition5.notify();
    
    /*
     * Sync
     */
    
    //no sync is performed, go right to sleep
    //  we will either be canceled or woken by the marker
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
