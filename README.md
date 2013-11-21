kgc
===
This is an alternative gc

It is very much a work in progress.

Note: 	relies on NPTL/pthreads
	and only has posix code

Build this by integrating with a copy of phobos/druntime
	Replace the contents of druntime/src/gc with the files in this repository
	Update the druntime MANIFEST and SRCS
	Update posix.mak in phobos and druntime to create the alternative lib

An example file is given to build using the alternative library