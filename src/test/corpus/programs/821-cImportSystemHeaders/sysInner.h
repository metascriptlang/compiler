#ifdef _WIN32
#include <winsock2.h>
#include <windows.h>
#else
#include <unistd.h>
#include <sys/utsname.h>
#ifdef __APPLE__
#include <sys/sysctl.h>
#include <mach/mach.h>
#endif
#endif

static inline int corpus821Branch(void) { return 2; }
