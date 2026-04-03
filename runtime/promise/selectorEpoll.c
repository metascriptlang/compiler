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
#include <sys/epoll.h>
#include <unistd.h>
#include <errno.h>

#define EPOLL_INIT_CAP 256

struct msSelector {
	int epfd;
	void** userData;    /* fd-indexed userdata array */
	int userDataCap;
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
	return sel;
}

void msSelectorDestroy(msSelector* sel) {
	if (sel == NULL) return;
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

int msSelectorPoll(msSelector* sel, int timeoutMs, msReadyEvent* out, int maxEvents) {
	struct epoll_event events[64];
	int limit = maxEvents < 64 ? maxEvents : 64;

	int nready;
	do {
		nready = epoll_wait(sel->epfd, events, limit, timeoutMs);
	} while (nready < 0 && errno == EINTR);

	if (nready < 0) return -1;

	for (int i = 0; i < nready; i++) {
		int fd = events[i].data.fd;
		out[i].fd = fd;
		out[i].userdata = (fd >= 0 && fd < sel->userDataCap) ? sel->userData[fd] : NULL;
		out[i].events = 0;

		if (events[i].events & EPOLLIN)
			out[i].events |= MS_EVENT_READ;
		if (events[i].events & EPOLLOUT)
			out[i].events |= MS_EVENT_WRITE;
		if (events[i].events & (EPOLLERR | EPOLLHUP))
			out[i].events |= MS_EVENT_ERROR;
	}

	return nready;
}

#endif /* __linux__ */
