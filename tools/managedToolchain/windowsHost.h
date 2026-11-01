#ifndef MS_TOOLCHAIN_WINDOWS_HOST_H
#define MS_TOOLCHAIN_WINDOWS_HOST_H

#include <stdint.h>
#ifdef _WIN32
#include <windows.h>

typedef BOOL (WINAPI *msToolchainWow64Query)(HANDLE, USHORT*, USHORT*);

static inline int32_t msToolchainNativeMachine(
	uint16_t* machine, uint32_t* error
) {
	*machine = 0;
	*error = 0;
	HMODULE kernel = GetModuleHandleW(L"kernel32.dll");
	if (!kernel) { *error = GetLastError(); return 0; }
	msToolchainWow64Query query = (msToolchainWow64Query)
		GetProcAddress(kernel, "IsWow64Process2");
	if (query) {
		USHORT process = 0;
		USHORT native = 0;
		if (!query(GetCurrentProcess(), &process, &native)) {
			*error = GetLastError();
			return 0;
		}
		*machine = native;
		return 1;
	}
	DWORD missing = GetLastError();
	if (missing != ERROR_PROC_NOT_FOUND) { *error = missing; return 0; }
	SYSTEM_INFO info;
	GetNativeSystemInfo(&info);
	switch (info.wProcessorArchitecture) {
	case PROCESSOR_ARCHITECTURE_AMD64: *machine = 0x8664; break;
	case PROCESSOR_ARCHITECTURE_ARM64: *machine = 0xaa64; break;
	case PROCESSOR_ARCHITECTURE_INTEL: *machine = 0x014c; break;
	case PROCESSOR_ARCHITECTURE_ARM: *machine = 0x01c4; break;
	default: *machine = 0; break;
	}
	return 1;
}
#endif
#endif
