/*
 * MetaScript OS Runtime — System information primitives
 *
 * Node.js os module parity: hostname, platform, arch, cpus, memory, uptime, etc.
 * Header-only, static inline (same pattern as std/net, std/process).
 */

#ifndef MS_STD_OS_H
#define MS_STD_OS_H

#include "runtime/core/system.h"
#include <string.h>
#include <time.h>

#ifdef _WIN32
#include <windows.h>
#else
#include <unistd.h>
#include <sys/utsname.h>
#ifdef __APPLE__
#include <sys/sysctl.h>
#include <mach/mach.h>
#endif
#endif

/* ===== hostname() ===== */

static inline msString msOsHostname(void) {
	char buf[256];
#ifdef _WIN32
	DWORD len = sizeof(buf);
	if (!GetComputerNameA(buf, &len)) return MS_EMPTY_STRING;
#else
	if (gethostname(buf, sizeof(buf)) != 0) return MS_EMPTY_STRING;
#endif
	return msStringFromCStr(buf);
}

/* ===== platform() — "darwin", "linux", "freebsd" ===== */

static inline msString msOsPlatform(void) {
#if defined(_WIN32)
	return msStringFromCStr("windows");
#elif defined(__APPLE__)
	return msStringFromCStr("darwin");
#elif defined(__linux__)
	return msStringFromCStr("linux");
#elif defined(__FreeBSD__)
	return msStringFromCStr("freebsd");
#elif defined(__OpenBSD__)
	return msStringFromCStr("openbsd");
#else
	return msStringFromCStr("unknown");
#endif
}

/* ===== arch() — "arm64", "x86_64" ===== */

static inline msString msOsArch(void) {
#ifdef _WIN32
	SYSTEM_INFO si;
	GetSystemInfo(&si);
	switch (si.wProcessorArchitecture) {
		case PROCESSOR_ARCHITECTURE_AMD64: return msStringFromCStr("x86_64");
		case PROCESSOR_ARCHITECTURE_ARM64: return msStringFromCStr("arm64");
		case PROCESSOR_ARCHITECTURE_INTEL: return msStringFromCStr("x86");
		default: return msStringFromCStr("unknown");
	}
#else
	struct utsname info;
	if (uname(&info) != 0) return MS_EMPTY_STRING;
	return msStringFromCStr(info.machine);
#endif
}

/* ===== type() — "Darwin", "Linux", "Windows_NT" ===== */

static inline msString msOsType(void) {
#ifdef _WIN32
	return msStringFromCStr("Windows_NT");
#else
	struct utsname info;
	if (uname(&info) != 0) return MS_EMPTY_STRING;
	return msStringFromCStr(info.sysname);
#endif
}

/* ===== release() — kernel version string ===== */

static inline msString msOsRelease(void) {
#ifdef _WIN32
	/* RtlGetVersion: accurate version without manifest (GetVersionEx lies on Win8.1+) */
	typedef LONG (WINAPI *RtlGetVersionFn)(OSVERSIONINFOW*);
	HMODULE ntdll = GetModuleHandleW(L"ntdll.dll");
	if (ntdll) {
		RtlGetVersionFn fn = (RtlGetVersionFn)GetProcAddress(ntdll, "RtlGetVersion");
		if (fn) {
			OSVERSIONINFOW vi;
			vi.dwOSVersionInfoSize = sizeof(vi);
			fn(&vi);
			char buf[32];
			snprintf(buf, sizeof(buf), "%lu.%lu.%lu",
			         vi.dwMajorVersion, vi.dwMinorVersion, vi.dwBuildNumber);
			return msStringFromCStr(buf);
		}
	}
	return msStringFromCStr("10.0");
#else
	struct utsname info;
	if (uname(&info) != 0) return MS_EMPTY_STRING;
	return msStringFromCStr(info.release);
#endif
}

/* ===== machine() — "arm64", "x86_64" (same as arch on most platforms) ===== */

static inline msString msOsMachine(void) {
	return msOsArch();
}

/* ===== CPU Info ===== */

typedef struct {
	msString model;
	int32_t speed;
} CpuInfo;

static inline int32_t msOsCpuCount(void) {
#ifdef _WIN32
	SYSTEM_INFO si;
	GetSystemInfo(&si);
	return si.dwNumberOfProcessors > 0 ? (int32_t)si.dwNumberOfProcessors : 1;
#elif defined(_SC_NPROCESSORS_ONLN)
	int n = (int)sysconf(_SC_NPROCESSORS_ONLN);
	return n > 0 ? (int32_t)n : 1;
#else
	return 1;
#endif
}

static inline msString msOsCpuModel(void) {
#if defined(_WIN32)
	/* Read CPU brand from registry */
	HKEY hKey;
	if (RegOpenKeyExA(HKEY_LOCAL_MACHINE, "HARDWARE\\DESCRIPTION\\System\\CentralProcessor\\0",
	                  0, KEY_READ, &hKey) == ERROR_SUCCESS) {
		char buf[256];
		DWORD len = sizeof(buf);
		if (RegQueryValueExA(hKey, "ProcessorNameString", NULL, NULL, (LPBYTE)buf, &len) == ERROR_SUCCESS) {
			RegCloseKey(hKey);
			return msStringFromCStr(buf);
		}
		RegCloseKey(hKey);
	}
	return msStringFromCStr("unknown");
#elif defined(__APPLE__)
	char buf[256];
	size_t len = sizeof(buf);
	if (sysctlbyname("machdep.cpu.brand_string", buf, &len, NULL, 0) == 0) {
		return msStringFromCStr(buf);
	}
#elif defined(__linux__)
	FILE *f = fopen("/proc/cpuinfo", "r");
	if (f) {
		char line[256];
		while (fgets(line, sizeof(line), f)) {
			if (strncmp(line, "model name", 10) == 0) {
				char *colon = strchr(line, ':');
				if (colon) {
					colon++;
					while (*colon == ' ') colon++;
					char *nl = strchr(colon, '\n');
					if (nl) *nl = '\0';
					fclose(f);
					return msStringFromCStr(colon);
				}
			}
		}
		fclose(f);
	}
#endif
	return msStringFromCStr("unknown");
}

static inline int32_t msOsCpuSpeed(void) {
#if defined(_WIN32)
	HKEY hKey;
	if (RegOpenKeyExA(HKEY_LOCAL_MACHINE, "HARDWARE\\DESCRIPTION\\System\\CentralProcessor\\0",
	                  0, KEY_READ, &hKey) == ERROR_SUCCESS) {
		DWORD mhz = 0, len = sizeof(mhz);
		if (RegQueryValueExA(hKey, "~MHz", NULL, NULL, (LPBYTE)&mhz, &len) == ERROR_SUCCESS) {
			RegCloseKey(hKey);
			return (int32_t)mhz;
		}
		RegCloseKey(hKey);
	}
	return 0;
#elif defined(__APPLE__)
	int64_t freq = 0;
	size_t len = sizeof(freq);
	if (sysctlbyname("hw.cpufrequency", &freq, &len, NULL, 0) == 0) {
		return (int32_t)(freq / 1000000);
	}
	return 0;
#elif defined(__linux__)
	FILE *f = fopen("/proc/cpuinfo", "r");
	if (f) {
		char line[256];
		while (fgets(line, sizeof(line), f)) {
			if (strncmp(line, "cpu MHz", 7) == 0) {
				char *colon = strchr(line, ':');
				if (colon) {
					fclose(f);
					return (int32_t)atof(colon + 1);
				}
			}
		}
		fclose(f);
	}
	return 0;
#else
	return 0;
#endif
}

/* Fill CpuInfo buffer via Span (out param). Returns count filled. */
static inline int32_t msOsCpus(CpuInfo* buf, int64_t buf_len) {
	int32_t count = msOsCpuCount();
	if (count > (int32_t)buf_len) count = (int32_t)buf_len;
	msString model = msOsCpuModel();
	int32_t speed = msOsCpuSpeed();
	for (int32_t i = 0; i < count; i++) {
		buf[i].model = model;
		buf[i].speed = speed;
	}
	return count;
}

/* ===== totalmem() — total system memory in bytes ===== */

static inline int64_t msOsTotalMem(void) {
#if defined(_WIN32)
	MEMORYSTATUSEX ms;
	ms.dwLength = sizeof(ms);
	if (GlobalMemoryStatusEx(&ms)) return (int64_t)ms.ullTotalPhys;
	return 0;
#elif defined(__APPLE__)
	int mib[2] = { CTL_HW, HW_MEMSIZE };
	int64_t mem = 0;
	size_t len = sizeof(mem);
	sysctl(mib, 2, &mem, &len, NULL, 0);
	return mem;
#elif defined(__linux__)
	long pages = sysconf(_SC_PHYS_PAGES);
	long pageSize = sysconf(_SC_PAGE_SIZE);
	return (int64_t)pages * (int64_t)pageSize;
#else
	return 0;
#endif
}

/* ===== freemem() — available memory in bytes ===== */

static inline int64_t msOsFreeMem(void) {
#if defined(_WIN32)
	MEMORYSTATUSEX ms;
	ms.dwLength = sizeof(ms);
	if (GlobalMemoryStatusEx(&ms)) return (int64_t)ms.ullAvailPhys;
	return 0;
#elif defined(__APPLE__)
	mach_port_t host = mach_host_self();
	vm_statistics64_data_t stats;
	mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
	if (host_statistics64(host, HOST_VM_INFO64, (host_info64_t)&stats, &count) != KERN_SUCCESS) return 0;
	return (int64_t)stats.free_count * (int64_t)sysconf(_SC_PAGE_SIZE);
#elif defined(__linux__)
	long pages = sysconf(_SC_AVPHYS_PAGES);
	long pageSize = sysconf(_SC_PAGE_SIZE);
	return (int64_t)pages * (int64_t)pageSize;
#else
	return 0;
#endif
}

/* ===== uptime() — system uptime in seconds ===== */

static inline double msOsUptime(void) {
#if defined(_WIN32)
	return (double)GetTickCount64() / 1000.0;
#elif defined(__APPLE__)
	struct timeval boottime;
	size_t len = sizeof(boottime);
	int mib[2] = { CTL_KERN, KERN_BOOTTIME };
	if (sysctl(mib, 2, &boottime, &len, NULL, 0) != 0) return 0.0;
	time_t now = time(NULL);
	return (double)(now - boottime.tv_sec);
#elif defined(__linux__)
	struct timespec ts;
	if (clock_gettime(CLOCK_BOOTTIME, &ts) != 0) return 0.0;
	return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
#else
	return 0.0;
#endif
}

/* ===== homedir() ===== */

static inline msString msOsHomedir(void) {
#ifdef _WIN32
	const char *home = getenv("USERPROFILE");
#else
	const char *home = getenv("HOME");
#endif
	if (home != NULL) return msStringFromCStr(home);
	return MS_EMPTY_STRING;
}

/* ===== tmpdir() ===== */

static inline msString msOsTmpdir(void) {
#ifdef _WIN32
	char buf[MAX_PATH];
	DWORD len = GetTempPathA(MAX_PATH, buf);
	if (len > 0) return msStringFromCStr(buf);
	return msStringFromCStr("C:\\Temp");
#else
	const char *tmp = getenv("TMPDIR");
	if (tmp != NULL) return msStringFromCStr(tmp);
	return msStringFromCStr("/tmp");
#endif
}

/* ===== endianness() — "LE" or "BE" ===== */

static inline msString msOsEndianness(void) {
	uint16_t test = 1;
	return msStringFromCStr(*(uint8_t*)&test ? "LE" : "BE");
}

#endif /* MS_STD_OS_H */
