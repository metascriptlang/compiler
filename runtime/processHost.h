#ifndef MS_PROCESS_HOST_H
#define MS_PROCESS_HOST_H

/* The CPU in --cpu spelling, from the C compiler: on iOS and Android the toolchain picks the triple
 * and msc's own cpu define does not see it. */
#if defined(__x86_64__) || defined(_M_X64)
#define MS_PROCESS_ARCH "amd64"
#elif defined(__aarch64__) || defined(_M_ARM64)
#define MS_PROCESS_ARCH "arm64"
#elif defined(__i386__) || defined(_M_IX86)
#define MS_PROCESS_ARCH "i386"
#elif defined(__arm__) || defined(_M_ARM)
#define MS_PROCESS_ARCH "arm"
#elif defined(__wasm32__)
#define MS_PROCESS_ARCH "wasm32"
#elif defined(__riscv) && __riscv_xlen == 64
#define MS_PROCESS_ARCH "riscv64"
#else
#define MS_PROCESS_ARCH "other"
#endif

/* The argv the generated main() records, for targets with no OS call that gives it. */
extern int cmdCount;
extern char** cmdLine;

#endif
