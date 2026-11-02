#include <float.h>
#include <math.h>
#include <stdio.h>
#include <windows.h>

/* Compiled with -fsyntax-only through a target's config, with EXPECT_AMD64 or EXPECT_ARM64 defined: the headers
   the config names must be the UCRT, Windows 10 ones of the architecture it was prepared for. */
#ifndef _UCRT
#error the headers do not select the UCRT
#endif
#if _WIN32_WINNT != 0x0A00
#error the default Windows version is not 0x0A00
#endif
#if __MSVCRT_VERSION__ != 0xE00
#error the default C runtime version is not 0xE00
#endif
#if !defined(_WIN64)
#error the target is not 64-bit Windows
#endif
#if defined(EXPECT_AMD64)
#if !defined(__x86_64__) || LDBL_MANT_DIG != 64
#error the config is not for x86_64
#endif
#elif defined(EXPECT_ARM64)
#if !defined(__aarch64__) || LDBL_MANT_DIG != 53
#error the config is not for aarch64
#endif
#else
#error name the expected architecture with EXPECT_AMD64 or EXPECT_ARM64
#endif

int main(void) {
    return 0;
}
