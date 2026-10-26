/*
 * The Raiser VM keeps strings in its own memory with the msString layout, at addresses
 * that are host addresses, so the read-only string runtime runs on them in place.
 * Allocation and growth stay with the VM's heap.
 */

#ifndef MS_VM_STRING_H
#define MS_VM_STRING_H

#include "runtime/core/string.h"

#define MS_VM_STRING_AT(addr) (*(msString*)(intptr_t)(addr))

static inline int64_t msVmTextLength(int64_t addr) { return msStringLength(MS_VM_STRING_AT(addr)); }
static inline int64_t msVmTextCharCodeAt(int64_t addr, int64_t idx) { return msStringCharCodeAt(MS_VM_STRING_AT(addr), idx); }
static inline int64_t msVmTextEquals(int64_t a, int64_t b) { return msStringEquals(MS_VM_STRING_AT(a), MS_VM_STRING_AT(b)); }
static inline int64_t msVmTextCompare(int64_t a, int64_t b) { return msStringCompare(MS_VM_STRING_AT(a), MS_VM_STRING_AT(b)); }
static inline msString msVmTextSlice(int64_t addr, int64_t start, int64_t end) { return msStringSlice(MS_VM_STRING_AT(addr), start, end); }

static inline msString msVmTextLoad(int64_t addr) {
	msString s = MS_VM_STRING_AT(addr);
	return s.len == 0 ? MS_EMPTY_STRING : msStringNew(s.p->data, s.len);
}

static inline void msVmTextStore(int64_t payloadData, msString s) {
	if (s.len > 0) memcpy((void*)(intptr_t)payloadData, s.p->data, (size_t)s.len);
	((char*)(intptr_t)payloadData)[s.len] = '\0';
}

/* The in-place append of msStringAppend for a destination the VM owns: false when the payload has to grow or is shared. */
static inline int64_t msVmTextTryAppend(int64_t dstAddr, int64_t srcAddr) {
	msString* dest = &MS_VM_STRING_AT(dstAddr);
	const msString src = MS_VM_STRING_AT(srcAddr);
	if (src.len == 0) return 1;
	msStrPayload* p = dest->p;
	if (p == NULL || p == src.p) return 0;
	msStringIsAscii(src);
	const int64_t cap = p->cap;
	const int64_t scap = msStrCapLoad(src.p);
	if (((cap & MS_STRLIT_FLAG) != 0) | (dest->len + src.len > (cap & MS_CAP_MASK))) return 0;
	memcpy(p->data + dest->len, src.p->data, (size_t)src.len);
	dest->len += src.len;
	p->data[dest->len] = '\0';
	if ((scap & MS_ASCII_FLAG) == 0) p->cap = (cap | MS_ASCII_CHECKED) & ~MS_ASCII_FLAG;
	return 1;
}

#endif
