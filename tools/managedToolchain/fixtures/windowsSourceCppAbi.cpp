#include <version>

#ifndef _LIBCPP_VERSION
#error "not libc++"
#endif
#if _LIBCPP_VERSION < 230000
#error "libc++ older than LLVM 23"
#endif
#ifndef _LIBCPP_DISABLE_VISIBILITY_ANNOTATIONS
#error "the static-only __config_site must disable visibility annotations"
#endif
#if !defined(__USE_MINGW_ANSI_STDIO) || __USE_MINGW_ANSI_STDIO != 1
#error "__config_site must set __USE_MINGW_ANSI_STDIO=1"
#endif
#if __cplusplus < 202002L
#error "C++20 expected"
#endif

static_assert(sizeof(void *) == 8, "64-bit target");
#if defined(EXPECT_AMD64)
static_assert(sizeof(long double) == 16, "x86_64 long double is the 80-bit format");
#elif defined(EXPECT_ARM64)
static_assert(sizeof(long double) == 8, "aarch64 Windows long double is a double");
#else
#error "define EXPECT_AMD64 or EXPECT_ARM64"
#endif
