#ifndef MS_HOST_CPU_H
#define MS_HOST_CPU_H

#include "runtime/core/system.h"
#include <stdio.h>

#if defined(__x86_64__) && (defined(__clang__) || defined(__GNUC__))
#include <cpuid.h>
#elif defined(__aarch64__) && defined(__APPLE__)
#include <sys/types.h>
#include <sys/sysctl.h>
#endif

/*
 * Everything clang reads to resolve -march=native or -mcpu=native on this machine (LLVM 23.1.4
 * TargetParser/Host.cpp): the cpuid leaves below and XCR0 on x86-64, hw.cpufamily on Apple arm64.
 * Empty where it reads something this does not: add that source here before a bundle targets such a host.
 */
static inline msString msHostCpuSignature(void) {
	char text[1024];
	int used = 0;
	text[0] = '\0';
#if defined(__x86_64__) && (defined(__clang__) || defined(__GNUC__))
	static const unsigned leaves[][2] = {
		{1, 0}, {7, 0}, {7, 1}, {0xd, 1}, {0x14, 0}, {0x19, 0}, {0x1e, 1}, {0x24, 0},
		{0x80000001u, 0}, {0x80000008u, 0}, {0x80000021u, 0},
	};
	unsigned a = 0, b = 0, c = 0, d = 0, osSavesState = 0;
	__cpuid(0, a, b, c, d);
	const unsigned top = a;
	used += snprintf(text + used, sizeof(text) - (size_t)used, "x86 %x %x %x %x", a, b, c, d);
	__cpuid(0x80000000u, a, b, c, d);
	const unsigned topExtended = a;
	for (size_t i = 0; i < sizeof(leaves) / sizeof(leaves[0]); i++) {
		const unsigned leaf = leaves[i][0];
		if (leaf > (leaf >= 0x80000000u ? topExtended : top)) continue;
		__cpuid_count(leaf, leaves[i][1], a, b, c, d);
		if (leaf == 1) {
			b = 0; /* EBX of leaf 1 holds the APIC id of the core that answered */
			osSavesState = (c >> 27) & 1;
		}
		used += snprintf(text + used, sizeof(text) - (size_t)used, " %x.%x %x %x %x %x", leaf, leaves[i][1], a, b, c, d);
	}
	if (osSavesState) {
		unsigned low = 0, high = 0;
		__asm__ volatile("xgetbv" : "=a"(low), "=d"(high) : "c"(0));
		used += snprintf(text + used, sizeof(text) - (size_t)used, " xcr0 %x %x", low, high);
	}
#elif defined(__aarch64__) && defined(__APPLE__)
	unsigned family = 0;
	size_t size = sizeof(family);
	if (sysctlbyname("hw.cpufamily", &family, &size, NULL, 0) == 0) used += snprintf(text, sizeof(text), "apple %x", family);
#endif
	(void)used;
	return msStringFromCStr(text);
}

#endif
