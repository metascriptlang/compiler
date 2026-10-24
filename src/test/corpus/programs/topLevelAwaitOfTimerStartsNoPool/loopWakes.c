#include <sys/resource.h>
#include "loopWakes.h"

#if defined(__APPLE__)
#include <mach/mach.h>

int32_t msTestOsThreads(void) {
	thread_act_array_t threads;
	mach_msg_type_number_t count = 0;
	if (task_threads(mach_task_self(), &threads, &count) != KERN_SUCCESS) return -1;
	for (mach_msg_type_number_t i = 0; i < count; i++) mach_port_deallocate(mach_task_self(), threads[i]);
	vm_deallocate(mach_task_self(), (vm_address_t)threads, count * sizeof(thread_act_t));
	return (int32_t)count;
}
#elif defined(__linux__)
#include <dirent.h>

int32_t msTestOsThreads(void) {
	DIR* d = opendir("/proc/self/task");
	if (d == NULL) return -1;
	int32_t count = 0;
	for (struct dirent* e = readdir(d); e != NULL; e = readdir(d)) {
		if (e->d_name[0] != '.') count++;
	}
	closedir(d);
	return count;
}
#else
#error "loopWakes.c counts OS threads on macOS and Linux only"
#endif

int32_t msTestContextSwitches(void) {
	struct rusage u;
	if (getrusage(RUSAGE_SELF, &u) != 0) return -1;
	return (int32_t)(u.ru_nvcsw + u.ru_nivcsw);
}
