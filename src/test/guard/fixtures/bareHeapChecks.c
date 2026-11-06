#include "runtime/core/system.h"
#include "bareHeapChecks.h"
#include <stddef.h>
#include <string.h>

static int msManualUnownedChecks(void) {
	msRefHeader first = {0}, second = {0};
	first.rc = 37;
	second.rc = 53;
	void* p = &first + 1;
	void* q = &second + 1;
	void* slot = p;
	msUnownedIncref(p);
	msUnownedDecref(p);
	msUnownedAssign(&slot, q);
	if (slot != q) return 1;
	int visits = 0;
	if (msUnownedTake((visits++, p)) != p || msUnownedGive((visits++, q)) != q || visits != 2) return 1;
	msUnownedIncref(NULL);
	msUnownedDecref(NULL);
	msUnownedAssign(&slot, NULL);
	if (slot != NULL || msUnownedTake(NULL) != NULL || msUnownedGive(NULL) != NULL) return 1;
	return first.rc != 37 || second.rc != 53;
}

int32_t msBareHeapReuseChecks(void) {
	if (msManualUnownedChecks()) return 8;
	/* An allocated big chunk forgets its left neighbour's size, as the reference does, so the pair
	 * coalesces only when the right block is freed first. */
	for (size_t round = 0; round < 2; round++) {
		void* left = msMemAlloc(24 * 1024);
		void* right = msMemAlloc(24 * 1024);
		unsigned char* held = msMemAlloc(160 * 1024);
		memset(held, 0x69, 160 * 1024);
		msBareHeapOtherUnitFree(right);
		free(left);
		void* merged = msMemAlloc(48 * 1024);
		memset(merged, 0x35, 48 * 1024);
		for (size_t j = 0; j < 160 * 1024; j++) {
			if (held[j] != 0x69) return 7;
		}
		free(merged);
		msBareHeapOtherUnitFree(held);
	}
	const size_t smallSizes[] = {1, 15, 16, 17, 31, 32, 33, 63, 64, 65, 127, 128, 129};
	const size_t middleSizes[] = {255, 256, 257, 511, 512, 513, 1023, 1024, 1025, 2047, 2048, 2049};
	const size_t largeSizes[] = {4031, 4032, 4033, 4095, 4096, 4097, 8191, 8192, 8193};
	for (size_t i = 0; i < 4096; i++) {
		size_t small = smallSizes[i % (sizeof(smallSizes) / sizeof(*smallSizes))];
		size_t middle = middleSizes[i % (sizeof(middleSizes) / sizeof(*middleSizes))];
		size_t large = largeSizes[i % (sizeof(largeSizes) / sizeof(*largeSizes))];
		unsigned char* a = msMemAlloc(small);
		unsigned char* b = msMemAlloc(middle);
		unsigned char* c = msMemAlloc(large);
		if ((uintptr_t)a % _Alignof(max_align_t) != 0 ||
			(uintptr_t)b % _Alignof(max_align_t) != 0 ||
			(uintptr_t)c % _Alignof(max_align_t) != 0) return 1;
		memset(a, 0x17, small);
		memset(b, 0x39, middle);
		memset(c, 0x75, large);
		msBareHeapOtherUnitFree(a);
		unsigned char* replacement = msMemAlloc(small);
		memset(replacement, 0xa7, small);
		for (size_t j = 0; j < middle; j++) if (b[j] != 0x39) return 2;
		for (size_t j = 0; j < large; j++) if (c[j] != 0x75) return 3;
		free(replacement);
		msBareHeapOtherUnitFree(c);
		free(b);
	}
	for (size_t i = 0; i < 128; i++) {
		unsigned char* p = msMemAllocN0(7, 19);
		for (size_t j = 0; j < 133; j++) if (p[j] != 0) return 4;
		memset(p, 0x5a, 133);
		p = msRealloc(p, 133, 8193);
		for (size_t j = 0; j < 133; j++) if (p[j] != 0x5a) return 5;
		p = msRealloc(p, 8193, 7);
		for (size_t j = 0; j < 7; j++) if (p[j] != 0x5a) return 6;
		msBareHeapOtherUnitFree(p);
	}
	free(msMemAlloc(0));
	free(NULL);
	void* empty = msRealloc(msMemAlloc(17), 17, 0);
	free(empty);
	return 0;
}

int32_t msBareHeapUseAfterFree(void) {
	volatile uintptr_t address = (uintptr_t)msMemAlloc(8);
	*((unsigned char*)address) = 42;
	free((void*)address);
	return *((volatile unsigned char*)address);
}
