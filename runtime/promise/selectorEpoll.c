#if !defined(MSOS_BARE) && !defined(MSOS_WASM) && !defined(MSOS_EMCC)
/*
 * MetaScript I/O Selector — epoll backend (Linux)
 *
 * Stores userdata in a fd-indexed array (epoll_event.data only holds fd).
 * This enables the async I/O engine and msNetRegisterRead/Write on Linux.
 */
#if defined(__linux__)

#include "runtime/actor/selector.h"
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <sys/epoll.h>
#include <sys/eventfd.h>
#include <unistd.h>
#include <errno.h>

#define EPOLL_INIT_CAP 256

struct msSelector {
	int epfd;
	void** userData;    /* fd-indexed userdata array */
	int userDataCap;
	int wakeFd;         /* eventfd for msSelectorWake (cross-thread targeted wake) */
};

static void growUserData(msSelector* sel, int fd) {
	if (fd < sel->userDataCap) return;
	int newCap = sel->userDataCap;
	while (newCap <= fd) newCap *= 2;
	sel->userData = (void**)realloc(sel->userData, newCap * sizeof(void*));
	memset(sel->userData + sel->userDataCap, 0, (newCap - sel->userDataCap) * sizeof(void*));
	sel->userDataCap = newCap;
}

msSelector* msSelectorCreate(void) {
	int epfd = epoll_create1(0);
	if (epfd < 0) return NULL;
	msSelector* sel = (msSelector*)calloc(1, sizeof(msSelector));
	sel->epfd = epfd;
	sel->userDataCap = EPOLL_INIT_CAP;
	sel->userData = (void**)calloc(EPOLL_INIT_CAP, sizeof(void*));
	/* Cross-thread wake (msSelectorWake): a self-resetting eventfd watched by this
	 * epoll. One write wakes one epoll_wait; the poll drains + skips it. */
	sel->wakeFd = eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC);
	if (sel->wakeFd >= 0) {
		struct epoll_event ev;
		ev.events = EPOLLIN;
		ev.data.fd = sel->wakeFd;
		epoll_ctl(epfd, EPOLL_CTL_ADD, sel->wakeFd, &ev);
	}
	return sel;
}

void msSelectorWake(msSelector* sel) {
	if (sel == NULL || sel->wakeFd < 0) return;
	uint64_t one = 1;
	ssize_t n = write(sel->wakeFd, &one, sizeof(one));
	(void)n;
}

void msSelectorDestroy(msSelector* sel) {
	if (sel == NULL) return;
	if (sel->wakeFd >= 0) close(sel->wakeFd);
	close(sel->epfd);
	free(sel->userData);
	free(sel);
}

static uint32_t msEventsToEpoll(uint32_t events) {
	uint32_t ep = 0;
	if (events & MS_EVENT_READ)  ep |= EPOLLIN;
	if (events & MS_EVENT_WRITE) ep |= EPOLLOUT;
	return ep;
}

int msSelectorRegister(msSelector* sel, int fd, uint32_t events, void* userdata) {
	growUserData(sel, fd);
	sel->userData[fd] = userdata;
	struct epoll_event ev;
	ev.events = msEventsToEpoll(events);
	ev.data.fd = fd;
	return epoll_ctl(sel->epfd, EPOLL_CTL_ADD, fd, &ev) < 0 ? -1 : 0;
}

int msSelectorUpdate(msSelector* sel, int fd, uint32_t events, void* userdata) {
	growUserData(sel, fd);
	sel->userData[fd] = userdata;
	struct epoll_event ev;
	ev.events = msEventsToEpoll(events);
	ev.data.fd = fd;
	return epoll_ctl(sel->epfd, EPOLL_CTL_MOD, fd, &ev) < 0 ? -1 : 0;
}

int msSelectorUnregister(msSelector* sel, int fd) {
	if (fd >= 0 && fd < sel->userDataCap) sel->userData[fd] = NULL;
	return epoll_ctl(sel->epfd, EPOLL_CTL_DEL, fd, NULL) < 0 ? -1 : 0;
}

int msSelectorGetFd(msSelector* sel) {
	if (sel == NULL) return -1;
	return sel->epfd;
}

int msSelectorPoll(msSelector* sel, int timeoutMs, msReadyEvent* out, int maxEvents) {
	struct epoll_event events[64];
	int limit = maxEvents < 64 ? maxEvents : 64;

	int nready;
	do {
		nready = epoll_wait(sel->epfd, events, limit, timeoutMs);
	} while (nready < 0 && errno == EINTR);

	if (nready < 0) return -1;

	int n = 0;
	for (int i = 0; i < nready; i++) {
		int fd = events[i].data.fd;
		/* msSelectorWake trigger: drain the eventfd + skip — it served only to return
		 * this poll (the caller re-checks actors via msRunOnce). */
		if (fd == sel->wakeFd) {
			uint64_t buf;
			ssize_t r = read(sel->wakeFd, &buf, sizeof(buf));
			(void)r;
			continue;
		}
		out[n].fd = fd;
		out[n].userdata = (fd >= 0 && fd < sel->userDataCap) ? sel->userData[fd] : NULL;
		out[n].events = 0;

		if (events[i].events & EPOLLIN)
			out[n].events |= MS_EVENT_READ;
		if (events[i].events & EPOLLOUT)
			out[n].events |= MS_EVENT_WRITE;
		if (events[i].events & (EPOLLERR | EPOLLHUP))
			out[n].events |= MS_EVENT_ERROR;
		n++;
	}

	return n;
}

#endif /* __linux__ */

#endif /* !MSOS_BARE && !MSOS_WASM */
