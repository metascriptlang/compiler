/*
 * msLocker memory layout — single source of truth shared by the DRC/ORC
 * implementation (promise/locker.h) and the --gc=manual stubs (manual.h).
 * Guard is independent of MS_LOCKER_H so manual.h can pull the layout in
 * while still blocking locker.h's threading body.
 */
#ifndef MS_LOCKER_LAYOUT_H
#define MS_LOCKER_LAYOUT_H

typedef struct {
	int nextTicket;
	int nowServing;
} msTicketLock;

typedef struct {
	msTicketLock lock;
	char data[];
} msLocker;

#endif
