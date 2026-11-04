/*
 * The crypto extensions this CPU has, read once per translation unit with the mechanisms the vendor files use:
 * cpuid on x86-64, getauxval(AT_HWCAP) on Linux aarch64, sysctl on Apple (SHA-256, AES and PMULL are part of every
 * Apple arm64 core; SHA-512 is hw.optional.armv8_2_sha512) and IsProcessorFeaturePresent on Windows on Arm.
 * A target without a mechanism reports no extension, so its callers keep their portable code.
 */

#ifndef MS_CRYPTO_CPU_FEATURES_H
#define MS_CRYPTO_CPU_FEATURES_H

#include <stdlib.h>

#define MS_CPU_SHA256 1
#define MS_CPU_SHA512 2
/* AES rounds plus the carry-less multiply GHASH uses: AES-NI + PCLMULQDQ (+ SSSE3, SSE4.1), or Arm AES + PMULL. */
#define MS_CPU_AES 4

#if defined(__x86_64__) && (defined(__clang__) || defined(__GNUC__))
#include <cpuid.h>
static inline int msCpuDetect(void) {
	unsigned eax, ebx, ecx, edx;
	int found = 0;
	if (!__get_cpuid(1, &eax, &ebx, &ecx, &edx)) return 0;
	const int ssse3 = (ecx >> 9) & 1, sse41 = (ecx >> 19) & 1, aes = (ecx >> 25) & 1, clmul = (ecx >> 1) & 1;
	if (ssse3 && sse41 && aes && clmul) found |= MS_CPU_AES;
	if (ssse3 && sse41 && __get_cpuid_count(7, 0, &eax, &ebx, &ecx, &edx) && ((ebx >> 29) & 1)) found |= MS_CPU_SHA256;
	return found;
}
#elif defined(__aarch64__) && defined(__linux__)
#include <sys/auxv.h>
static inline int msCpuDetect(void) {
	const unsigned long hw = getauxval(AT_HWCAP);
	int found = 0;
	if (hw & (1UL << 6)) found |= MS_CPU_SHA256;           /* HWCAP_SHA2 */
	if (hw & (1UL << 21)) found |= MS_CPU_SHA512;          /* HWCAP_SHA512 */
	if ((hw & (1UL << 3)) && (hw & (1UL << 4))) found |= MS_CPU_AES; /* HWCAP_AES, HWCAP_PMULL */
	return found;
}
#elif defined(__aarch64__) && defined(__APPLE__)
#include <sys/types.h>
#include <sys/sysctl.h>
static inline int msCpuDetect(void) {
	int value = 0;
	size_t size = sizeof(value);
	int found = MS_CPU_SHA256 | MS_CPU_AES;
	if (sysctlbyname("hw.optional.armv8_2_sha512", &value, &size, NULL, 0) == 0 && value != 0) found |= MS_CPU_SHA512;
	return found;
}
#elif defined(_M_ARM64) || (defined(__aarch64__) && defined(_WIN32))
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
static inline int msCpuDetect(void) {
	return IsProcessorFeaturePresent(PF_ARM_V8_CRYPTO_INSTRUCTIONS_AVAILABLE) ? (MS_CPU_SHA256 | MS_CPU_AES) : 0;
}
#else
static inline int msCpuDetect(void) {
	return 0;
}
#endif

/* The extensions the CPU has, cached after the first call. */
static inline int msCpuFeatures(void) {
	static int cached = -1;
	int known = __atomic_load_n(&cached, __ATOMIC_RELAXED);
	if (known < 0) {
		known = msCpuDetect();
		__atomic_store_n(&cached, known, __ATOMIC_RELAXED);
	}
	return known;
}

/* True when MS_CRYPTO_PORTABLE is set to anything but "" or "0": the portable std/crypto modules then run their own
 * code on every CPU, so a test can cover it on a machine that has the extensions. */
static inline int msCryptoPortableForced(void) {
	static int cached = -1;
	int known = __atomic_load_n(&cached, __ATOMIC_RELAXED);
	if (known < 0) {
		const char *portable = getenv("MS_CRYPTO_PORTABLE");
		known = portable != NULL && portable[0] != '\0' && !(portable[0] == '0' && portable[1] == '\0');
		__atomic_store_n(&cached, known, __ATOMIC_RELAXED);
	}
	return known;
}

/* What the portable std/crypto modules may use: the CPU's extensions, or none when the portable code is forced. */
static inline int msPureCpuFeatures(void) {
	return msCryptoPortableForced() ? 0 : msCpuFeatures();
}

#endif /* MS_CRYPTO_CPU_FEATURES_H */
