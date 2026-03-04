/*
 * MetaScript I/O Selector — platform-agnostic event notification
 *
 * Abstracts kqueue (macOS/BSD), epoll (Linux), and poll (POSIX fallback)
 * behind a unified interface for the async dispatcher.
 */
#ifndef MS_SELECTOR_H
#define MS_SELECTOR_H

#include <stdbool.h>
#include <stdint.h>

/* Event flags (bitmask) */
#define MS_EVENT_READ   1
#define MS_EVENT_WRITE  2
#define MS_EVENT_ERROR  4

/* A ready event returned by msSelectorPoll */
typedef struct {
	int fd;
	uint32_t events;    /* bitmask of MS_EVENT_* */
	void* userdata;     /* e.g. msFuture* */
} msReadyEvent;

/* Opaque selector handle */
typedef struct msSelector msSelector;

/* Create a new selector (kqueue/epoll/poll depending on platform) */
msSelector* msSelectorCreate(void);

/* Destroy selector and release OS resources */
void msSelectorDestroy(msSelector* sel);

/* Register fd for event notification. Returns 0 on success, -1 on error. */
int msSelectorRegister(msSelector* sel, int fd, uint32_t events, void* userdata);

/* Update events/userdata for an already-registered fd. Returns 0 on success, -1 on error. */
int msSelectorUpdate(msSelector* sel, int fd, uint32_t events, void* userdata);

/* Unregister fd. Returns 0 on success, -1 on error. */
int msSelectorUnregister(msSelector* sel, int fd);

/* Poll for ready events. Returns number of ready events (0 on timeout, -1 on error).
 * Results written to out array, up to maxEvents entries. */
int msSelectorPoll(msSelector* sel, int timeoutMs, msReadyEvent* out, int maxEvents);

#endif /* MS_SELECTOR_H */
