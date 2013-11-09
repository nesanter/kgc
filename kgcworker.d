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

private __gshared bool sweepFinished;

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
	if (!marker.running)
		marker.launch();
	if (!sweeper.running)
		sweeper.launch();
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

void signal_workers() {
	marker.sigUser2();
	sweeper.sigUser2();
}

void marker_fn() {
	//Respond to signal
	signal(SIGUSR2, &marker_handler);
	
	while (true) {
		
		/*
		 *  Wait
		 */
		
		while (_gc.collectInProgress == CollectMode.OFF) {
			sched_yield();
		}
		_gc.collectInProgress = CollectMode.ON;
		
		/*
		 *  Main
		 */
		
		printf("MARK!\n");
		
		/*
		 *  Sync
		 */
		
		while (!sweepFinished) {
			//wait for sweeper
			sched_yield();
		}
		sweepFinished = false;
		if (!_gc.collectStopThreshold()) {
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
	
	while (true) {
		
		/*
		 *  Wait
		 */
		
		while (_gc.collectInProgress == CollectMode.OFF) {
			sched_yield();
		}
		
		/*
		 *  Main
		 */
		 
		printf("SWEEP!\n");
		
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
		printf("(cleanup)\n");
		pthread_exit(null);
	} else {
		printf("Unknown signal received\n");
	}
}

extern (C) void sweeper_handler(int sig) nothrow {
	if (sig == SIGUSR2) {
		printf("SIGUSR2 RECEIVED\n");
		printf("(cleanup)\n");
		pthread_exit(null);
	} else {
		printf("Unknown signal received\n");
	}
}
