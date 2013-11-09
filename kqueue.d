module gc.implement_queue;

import clib = core.stdc.stdlib : malloc, calloc, realloc, free;
import slib = core.stdc.string : memset;
import core.sync.mutex;
import core.atomic;

immutable ulong RQMAX = 16;

alias ubyte request_t;

final class GCMutex : Mutex {}


struct GCQueue {
	
	__gshared GCMutex gcLock;
	__gshared byte[__traits(classInstanceSize, GCMutex)] mutexStorage;
	
	request_t rcount;
	Request[RQMAX] queue;
	
	void initialize() {
		mutexStorage[] = GCMutex.classinfo.init[];
		gcLock = cast(GCMutex)mutexStorage.ptr;
		gcLock.__ctor();
	}
	
	request_t enqueue_malloc(size_t sz, uint bits, size_t* alloc_size) {
		bool blocked;
		request_t r;
		do {
			{
				gcLock.lock();
				scope (exit) gcLock.unlock();
				if (rcount < RQMAX) {
					r = rcount++;
				} else {
					blocked = true;
				}
			}
		} while (blocked);
		
		queue[r] = Request(RequestType.MALLOC, [sz, cast(ulong)bits, cast(ulong)alloc_size, 0]);
		
		return r;
	}
	
	void wait(request_t r) {
		
	}
}

private enum RequestType : ubyte { MALLOC }

private struct Request {
	RequestType type;
	ulong[4] paramaters;
}
