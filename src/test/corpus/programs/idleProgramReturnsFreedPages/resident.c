#include <stdio.h>
#include "resident.h"
#if defined(_WIN32)
#define PSAPI_VERSION 2
#include <windows.h>
#include <psapi.h>
int64_t probeResidentKb(void) {
	PROCESS_MEMORY_COUNTERS c;
	if (!GetProcessMemoryInfo(GetCurrentProcess(), &c, sizeof c)) return -1;
	return (int64_t)(c.WorkingSetSize / 1024);
}
#elif defined(__APPLE__)
#include <mach/mach.h>
/* The footprint, which the OS charges the task for; resident size still counts reusable pages. */
int64_t probeResidentKb(void) {
	task_vm_info_data_t info;
	mach_msg_type_number_t n = TASK_VM_INFO_COUNT;
	if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &n) != KERN_SUCCESS) return -1;
	return (int64_t)(info.phys_footprint / 1024);
}
#else
#include <unistd.h>
int64_t probeResidentKb(void) {
	long pages = 0, resident = -1;
	FILE* f = fopen("/proc/self/statm", "r");
	if (f == NULL) return -1;
	if (fscanf(f, "%ld %ld", &pages, &resident) != 2) resident = -1;
	fclose(f);
	return resident < 0 ? -1 : (int64_t)resident * (sysconf(_SC_PAGESIZE) / 1024);
}
#endif
