#if !defined(MSOS_BARE) && !defined(MSOS_WASM) && !defined(MSOS_EMCC)
/*
 * MetaScript I/O Selector — kqueue backend (macOS, FreeBSD, OpenBSD, NetBSD)
 */
#if defined(__APPLE__) || defined(__FreeBSD__) || defined(__OpenBSD__) || defined(__NetBSD__)

#include "runtime/actor/selector.h"
#include <stdlib.h>
#include <sys/types.h>
#include <sys/event.h>
#include <sys/time.h>
#include <unistd.h>
#include <errno.h>

struct msSelector {
	int kqfd;
};

msSelector* msSelectorCreate(void) {
	int kqfd = kqueue();
	if (kqfd < 0) return NULL;
	msSelector* sel = (msSelector*)malloc(sizeof(msSelector));
	sel->kqfd = kqfd;
	return sel;
}

void msSelectorDestroy(msSelector* sel) {
	if (sel == NULL) return;
	close(sel->kqfd);
	free(sel);
}

int msSelectorRegister(msSelector* sel, int fd, uint32_t events, void* userdata) {
	struct kevent changes[2];
	int nchanges = 0;

	if (events & MS_EVENT_READ) {
		EV_SET(&changes[nchanges], fd, EVFILT_READ, EV_ADD | EV_ENABLE, 0, 0, userdata);
		nchanges++;
	}
	if (events & MS_EVENT_WRITE) {
		EV_SET(&changes[nchanges], fd, EVFILT_WRITE, EV_ADD | EV_ENABLE, 0, 0, userdata);
		nchanges++;
	}
	if (nchanges == 0) return -1;

	int ret = kevent(sel->kqfd, changes, nchanges, NULL, 0, NULL);
	return ret < 0 ? -1 : 0;
}

int msSelectorUpdate(msSelector* sel, int fd, uint32_t events, void* userdata) {
	/* kqueue: delete old filters, add new ones */
	struct kevent deletes[2];
	EV_SET(&deletes[0], fd, EVFILT_READ, EV_DELETE, 0, 0, NULL);
	EV_SET(&deletes[1], fd, EVFILT_WRITE, EV_DELETE, 0, 0, NULL);
	/* Ignore errors from deleting non-existent filters */
	kevent(sel->kqfd, deletes, 2, NULL, 0, NULL);

	return msSelectorRegister(sel, fd, events, userdata);
}

int msSelectorUnregister(msSelector* sel, int fd) {
	struct kevent deletes[2];
	EV_SET(&deletes[0], fd, EVFILT_READ, EV_DELETE, 0, 0, NULL);
	EV_SET(&deletes[1], fd, EVFILT_WRITE, EV_DELETE, 0, 0, NULL);
	/* Ignore errors from deleting non-existent filters */
	kevent(sel->kqfd, deletes, 2, NULL, 0, NULL);
	return 0;
}

int msSelectorGetFd(msSelector* sel) {
	if (sel == NULL) return -1;
	return sel->kqfd;
}

int msSelectorPoll(msSelector* sel, int timeoutMs, msReadyEvent* out, int maxEvents) {
	struct timespec ts;
	struct timespec* tsp = NULL;

	if (timeoutMs >= 0) {
		ts.tv_sec = timeoutMs / 1000;
		ts.tv_nsec = (timeoutMs % 1000) * 1000000L;
		tsp = &ts;
	}

	/* Stack buffer for kevent results */
	struct kevent kevents[64];
	int limit = maxEvents < 64 ? maxEvents : 64;

	int nready;
	do {
		nready = kevent(sel->kqfd, NULL, 0, kevents, limit, tsp);
	} while (nready < 0 && errno == EINTR);

	if (nready < 0) return -1;

	for (int i = 0; i < nready; i++) {
		out[i].fd = (int)kevents[i].ident;
		out[i].userdata = kevents[i].udata;
		out[i].events = 0;

		if (kevents[i].filter == EVFILT_READ)
			out[i].events |= MS_EVENT_READ;
		if (kevents[i].filter == EVFILT_WRITE)
			out[i].events |= MS_EVENT_WRITE;
		if (kevents[i].flags & EV_EOF || kevents[i].flags & EV_ERROR)
			out[i].events |= MS_EVENT_ERROR;
	}

	return nready;
}

#endif /* __APPLE__ || __FreeBSD__ || __OpenBSD__ || __NetBSD__ */

#endif /* !MSOS_BARE && !MSOS_WASM */
