#if !defined(MSOS_BARE) && !defined(MSOS_WASM) && !defined(MSOS_EMCC)
/*
 * MetaScript I/O Selector — poll() fallback (POSIX, Windows via WSAPoll)
 *
 * Used when neither kqueue nor epoll is available.
 * Linear scan, but works everywhere.
 */
#if !defined(__APPLE__) && !defined(__FreeBSD__) && !defined(__OpenBSD__) && \
    !defined(__NetBSD__) && !defined(__linux__)

#include "runtime/actor/selector.h"
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#include <winsock2.h>
#define poll WSAPoll
typedef ULONG nfds_t;
#else
#include <poll.h>
#endif

#define MS_POLL_INIT_CAP 16

struct msSelector {
	struct pollfd* fds;
	void** userdata;
	int len;
	int cap;
};

msSelector* msSelectorCreate(void) {
	msSelector* sel = (msSelector*)calloc(1, sizeof(msSelector));
	sel->cap = MS_POLL_INIT_CAP;
	sel->fds = (struct pollfd*)calloc(sel->cap, sizeof(struct pollfd));
	sel->userdata = (void**)calloc(sel->cap, sizeof(void*));
	return sel;
}

void msSelectorDestroy(msSelector* sel) {
	if (sel == NULL) return;
	free(sel->fds);
	free(sel->userdata);
	free(sel);
}

static short msEventsToPoll(uint32_t events) {
	short p = 0;
	if (events & MS_EVENT_READ)  p |= POLLIN;
	if (events & MS_EVENT_WRITE) p |= POLLOUT;
	return p;
}

/* Find index of fd, or -1 */
static int msPollFind(msSelector* sel, int fd) {
	for (int i = 0; i < sel->len; i++) {
		if (sel->fds[i].fd == fd) return i;
	}
	return -1;
}

int msSelectorRegister(msSelector* sel, int fd, uint32_t events, void* userdata) {
	if (msPollFind(sel, fd) >= 0) return -1; /* already registered */
	if (sel->len >= sel->cap) {
		int newCap = sel->cap * 2;
		sel->fds = (struct pollfd*)realloc(sel->fds, newCap * sizeof(struct pollfd));
		sel->userdata = (void**)realloc(sel->userdata, newCap * sizeof(void*));
		sel->cap = newCap;
	}
	sel->fds[sel->len].fd = fd;
	sel->fds[sel->len].events = msEventsToPoll(events);
	sel->fds[sel->len].revents = 0;
	sel->userdata[sel->len] = userdata;
	sel->len++;
	return 0;
}

int msSelectorUpdate(msSelector* sel, int fd, uint32_t events, void* userdata) {
	int idx = msPollFind(sel, fd);
	if (idx < 0) return -1;
	sel->fds[idx].events = msEventsToPoll(events);
	sel->userdata[idx] = userdata;
	return 0;
}

int msSelectorUnregister(msSelector* sel, int fd) {
	int idx = msPollFind(sel, fd);
	if (idx < 0) return -1;
	/* Swap with last */
	sel->len--;
	if (idx < sel->len) {
		sel->fds[idx] = sel->fds[sel->len];
		sel->userdata[idx] = sel->userdata[sel->len];
	}
	return 0;
}

int msSelectorPoll(msSelector* sel, int timeoutMs, msReadyEvent* out, int maxEvents) {
	if (sel->len == 0) {
		/* No fds to poll — just sleep for timeout */
		if (timeoutMs > 0) {
#ifdef _WIN32
			Sleep(timeoutMs);
#else
			struct timespec ts;
			ts.tv_sec = timeoutMs / 1000;
			ts.tv_nsec = (timeoutMs % 1000) * 1000000L;
			nanosleep(&ts, NULL);
#endif
		}
		return 0;
	}

	int ret = poll(sel->fds, (nfds_t)sel->len, timeoutMs);
	if (ret <= 0) return ret;

	int count = 0;
	for (int i = 0; i < sel->len && count < maxEvents; i++) {
		if (sel->fds[i].revents == 0) continue;
		out[count].fd = sel->fds[i].fd;
		out[count].userdata = sel->userdata[i];
		out[count].events = 0;
		if (sel->fds[i].revents & POLLIN)
			out[count].events |= MS_EVENT_READ;
		if (sel->fds[i].revents & POLLOUT)
			out[count].events |= MS_EVENT_WRITE;
		if (sel->fds[i].revents & (POLLERR | POLLHUP | POLLNVAL))
			out[count].events |= MS_EVENT_ERROR;
		count++;
	}

	return count;
}

#if !defined(_WIN32)
#include <time.h>
#endif

#endif /* fallback guard */

#endif /* !MSOS_BARE && !MSOS_WASM */
