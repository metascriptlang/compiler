/*
 * MetaScript I/O Selector — epoll backend (Linux)
 */
#if defined(__linux__)

#include "selector.h"
#include <stdlib.h>
#include <sys/epoll.h>
#include <unistd.h>
#include <errno.h>

struct msSelector {
	int epfd;
};

msSelector* msSelectorCreate(void) {
	int epfd = epoll_create1(0);
	if (epfd < 0) return NULL;
	msSelector* sel = (msSelector*)malloc(sizeof(msSelector));
	sel->epfd = epfd;
	return sel;
}

void msSelectorDestroy(msSelector* sel) {
	if (sel == NULL) return;
	close(sel->epfd);
	free(sel);
}

static uint32_t msEventsToEpoll(uint32_t events) {
	uint32_t ep = 0;
	if (events & MS_EVENT_READ)  ep |= EPOLLIN;
	if (events & MS_EVENT_WRITE) ep |= EPOLLOUT;
	return ep;
}

int msSelectorRegister(msSelector* sel, int fd, uint32_t events, void* userdata) {
	struct epoll_event ev;
	ev.events = msEventsToEpoll(events);
	ev.data.ptr = userdata;
	return epoll_ctl(sel->epfd, EPOLL_CTL_ADD, fd, &ev) < 0 ? -1 : 0;
}

int msSelectorUpdate(msSelector* sel, int fd, uint32_t events, void* userdata) {
	struct epoll_event ev;
	ev.events = msEventsToEpoll(events);
	ev.data.ptr = userdata;
	return epoll_ctl(sel->epfd, EPOLL_CTL_MOD, fd, &ev) < 0 ? -1 : 0;
}

int msSelectorUnregister(msSelector* sel, int fd) {
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
		out[i].fd = -1;  /* epoll doesn't directly expose fd in events */
		out[i].userdata = events[i].data.ptr;
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
