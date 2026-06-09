#if !defined(MSOS_BARE) && !defined(MSOS_WASM) && !defined(MSOS_EMCC)
/*
 * MetaScript I/O Selector — kqueue backend (macOS, FreeBSD, OpenBSD, NetBSD)
 */
#if defined(__APPLE__) || defined(__FreeBSD__) || defined(__OpenBSD__) || defined(__NetBSD__)

#include "runtime/actor/selector.h"
#include <stdio.h>
#include <stdlib.h>
#include <sys/types.h>
#include <sys/event.h>
#include <sys/time.h>
#include <unistd.h>
#include <errno.h>

struct msSelector {
	int kqfd;
};

/* Reserved EVFILT_USER ident for msSelectorWake. EVFILT_USER lives in a filter
 * namespace separate from EVFILT_READ/WRITE, so this never collides with a real
 * fd registration regardless of value. */
#define MS_SELECTOR_WAKE_IDENT ((uintptr_t)0xACC0DE)

msSelector* msSelectorCreate(void) {
	int kqfd = kqueue();
	if (kqfd < 0) return NULL;
	msSelector* sel = (msSelector*)malloc(sizeof(msSelector));
	sel->kqfd = kqfd;
	/* Self-clearing cross-thread wake (EV_CLEAR auto-resets after each delivery,
	 * so msSelectorWake needs no drain — see msSelectorPoll which skips it). */
	struct kevent wake;
	EV_SET(&wake, MS_SELECTOR_WAKE_IDENT, EVFILT_USER, EV_ADD | EV_CLEAR, 0, 0, NULL);
	kevent(kqfd, &wake, 1, NULL, 0, NULL);
	return sel;
}

void msSelectorWake(msSelector* sel) {
	if (sel == NULL) return;
	struct kevent ev;
	EV_SET(&ev, MS_SELECTOR_WAKE_IDENT, EVFILT_USER, 0, NOTE_TRIGGER, 0, NULL);
	kevent(sel->kqfd, &ev, 1, NULL, 0, NULL);
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
	/* kqueue: delete old filters, add new ones. Same eventlist guard as
	 * msSelectorUnregister — NULL eventlist would abort kevent() on the
	 * first ENOENT, leaving the other filter live and the subsequent
	 * msSelectorRegister adding on top of stale state. */
	struct kevent deletes[2];
	struct kevent errs[2];
	EV_SET(&deletes[0], fd, EVFILT_READ,  EV_DELETE, 0, 0, NULL);
	EV_SET(&deletes[1], fd, EVFILT_WRITE, EV_DELETE, 0, 0, NULL);
	int n = kevent(sel->kqfd, deletes, 2, errs, 2, NULL);
	if (n > 0) {
		for (int i = 0; i < n; i++) {
			if ((errs[i].flags & EV_ERROR) == 0) continue;
			if (errs[i].data == 0 || errs[i].data == ENOENT) continue;
			fprintf(stderr,
				"FATAL: kevent EV_DELETE (update) failed on fd=%d filter=%d data=%lld — selector state diverged.\n",
				(int)errs[i].ident, (int)errs[i].filter, (long long)errs[i].data);
			abort();
		}
	}

	return msSelectorRegister(sel, fd, events, userdata);
}

int msSelectorUnregister(msSelector* sel, int fd) {
	struct kevent deletes[2];
	struct kevent errs[2];
	EV_SET(&deletes[0], fd, EVFILT_READ,  EV_DELETE, 0, 0, NULL);
	EV_SET(&deletes[1], fd, EVFILT_WRITE, EV_DELETE, 0, 0, NULL);
	/* Eventlist absorbs per-change errors. Without it, NULL eventlist makes
	 * kevent() abort on the first ENOENT and skip the rest — so a one-shot
	 * recv leaves the WRITE filter live and vice versa. The leaked filter
	 * then re-fires level-triggered on the next poll, dispatched against a
	 * pool-reused request whose op no longer matches (recv routed to write
	 * path or vice versa). */
	int n = kevent(sel->kqfd, deletes, 2, errs, 2, NULL);
	if (n < 0) return -1;
	for (int i = 0; i < n; i++) {
		if ((errs[i].flags & EV_ERROR) == 0) continue;
		if (errs[i].data == 0 || errs[i].data == ENOENT) continue;  /* filter wasn't registered — fine */
		fprintf(stderr,
			"FATAL: kevent EV_DELETE failed on fd=%d filter=%d data=%lld — selector state diverged.\n",
			(int)errs[i].ident, (int)errs[i].filter, (long long)errs[i].data);
		abort();
	}
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

	int n = 0;
	for (int i = 0; i < nready; i++) {
		/* msSelectorWake trigger: it has already done its job (woke this poll).
		 * Don't surface it as a ready fd event — the caller re-checks actors via
		 * msRunOnce after the poll returns. EV_CLEAR self-resets it. */
		if (kevents[i].filter == EVFILT_USER) continue;

		out[n].fd = (int)kevents[i].ident;
		out[n].userdata = kevents[i].udata;
		out[n].events = 0;

		if (kevents[i].filter == EVFILT_READ)
			out[n].events |= MS_EVENT_READ;
		if (kevents[i].filter == EVFILT_WRITE)
			out[n].events |= MS_EVENT_WRITE;
		if (kevents[i].flags & EV_EOF || kevents[i].flags & EV_ERROR)
			out[n].events |= MS_EVENT_ERROR;
		n++;
	}

	return n;
}

#endif /* __APPLE__ || __FreeBSD__ || __OpenBSD__ || __NetBSD__ */

#endif /* !MSOS_BARE && !MSOS_WASM */
