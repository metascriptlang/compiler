#include "runtime/core/system.h"
#include "bareHeapChecks.h"
#include <stddef.h>
#include <string.h>

int32_t msBareHeapReuseChecks(void) {
	for (size_t i = 0; i < 4096; i++) {
		size_t small = 17 + i % 113;
		size_t middle = 513 + i % 997;
		size_t large = 4097 + i % 4096;
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
	return 0;
}
