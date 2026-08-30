/* wintime — the Windows stand-in for `/usr/bin/time -l`, used only by the
 * corpus runner's RSS cells (src/test/corpus/run.ms).
 *
 * Windows has no `time` utility, and the obvious substitutes do not work:
 * PowerShell's Process.PeakWorkingSet64 reads back EMPTY once the child has
 * exited (.NET invalidates the cached counters), and polling a running process
 * cannot see a peak it missed between samples. GetProcessMemoryInfo on a handle
 * we still hold keeps reporting after exit, so that is what this does.
 *
 * Output is deliberately byte-shaped like the macOS `time -l` line the runner
 * already parses (parseRssMB slices everything before "maximum"):
 *
 *             67158016  maximum resident set size
 *
 * It goes to stderr, and the child inherits stderr, so a cell's time.log holds
 * both the child's diagnostics and this line — same as on macOS.
 *
 * The child's exit status is forwarded verbatim: the RSS cells grade on it.
 *
 * `wintime --sleep-ms <n>` is a second mode, and it is here rather than in its
 * own binary only to avoid shipping two helpers. The runner's poll loop wants a
 * sub-second sleep and Windows ships nothing usable: `timeout` refuses to run
 * when stdin is redirected, and `ping` as a timer depends on how the host
 * answers an unroutable address. One Sleep() call is exact and has neither
 * failure mode.
 *
 * `wintime --detach <command>` is the third mode: spawn and return immediately.
 * It exists because the shell's own backgrounding cannot work here. POSIX `&`
 * has no cmd.exe equivalent, and `start /b` does NOT background through
 * std/process.exec: msProcessSpawnSync hands the child INHERITABLE pipe write
 * ends, so every descendant holds a duplicate and the parent's drain loop
 * blocks until the last one exits — measured, and true even with `>nul 2>&1` or
 * a separate console, because inheritance copies the handles whether or not the
 * child uses them as stdio.
 *
 * Two knobs are needed and NEITHER works alone (all four combinations were
 * measured on a 1.2 s cell, twice each):
 *
 *   bInheritHandles=FALSE   cuts the tie to the drained pipes. With TRUE the
 *                           launch blocks ~1260 ms — the cell's whole run —
 *                           whatever the creation flags say.
 *   CREATE_NO_WINDOW        keeps the grandchild off our console. NOT
 *                           DETACHED_PROCESS: that also returns in ~80 ms, but
 *                           the cell's log comes back 0 bytes, so every parity
 *                           byte-compare would run on empty files. Detaching
 *                           from the console evidently costs the child the
 *                           std handles it needs to open its own redirects.
 *
 * FALSE + CREATE_NO_WINDOW: ~55 ms spawn, full 26-byte log. That is the pair.
 *
 * The detached process gets no stdio from us, so the caller's command must do
 * its own redirection (the runner's per-cell .bat does).
 *
 * Build (the runner does this once per run, into out/corpus/):
 *     zig cc -O2 wintime.c -o wintime.exe -lpsapi
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <windows.h>
#include <psapi.h>

int main(void) {
	/* Take the tail of our own command line verbatim rather than re-quoting
	 * argv[]: the cell command is already a correctly quoted Windows command
	 * line, and round-tripping it through argv would lose that quoting. */
	char* p = GetCommandLineA();
	if (*p == '"') {
		p++;
		while (*p && *p != '"') p++;
		if (*p) p++;
	} else {
		while (*p && *p != ' ') p++;
	}
	while (*p == ' ') p++;
	if (*p == '\0') {
		fprintf(stderr, "wintime: usage: wintime <command> [args...]\n");
		fprintf(stderr, "                wintime --sleep-ms <n>\n");
		fprintf(stderr, "                wintime --detach <command> [args...]\n");
		fprintf(stderr, "                wintime --mtime <path>\n");
		return 127;
	}

	if (strncmp(p, "--sleep-ms", 10) == 0) {
		const char* n = p + 10;
		while (*n == ' ') n++;
		Sleep((DWORD)strtoul(n, NULL, 10));
		return 0;
	}

	if (strncmp(p, "--mtime", 7) == 0) {
		char* path = p + 7;
		while (*path == ' ') path++;
		/* The path may be quoted (it comes from the runner, which quotes every
		 * path it emits); strip one surrounding pair. */
		if (*path == '"') {
			char* end = ++path;
			while (*end && *end != '"') end++;
			*end = '\0';
		}
		WIN32_FILE_ATTRIBUTE_DATA fad;
		if (!GetFileAttributesExA(path, GetFileExInfoStandard, &fad)) return 1;
		ULONGLONG t = ((ULONGLONG)fad.ftLastWriteTime.dwHighDateTime << 32)
		            | (ULONGLONG)fad.ftLastWriteTime.dwLowDateTime;
		/* FILETIME counts 100 ns ticks from 1601-01-01; shift to the Unix
		 * epoch so the output is directly comparable with `git log %ct`. */
		printf("%llu\n", (t - 116444736000000000ULL) / 10000000ULL);
		return 0;
	}

	int detach = 0;
	if (strncmp(p, "--detach", 8) == 0) {
		detach = 1;
		p += 8;
		while (*p == ' ') p++;
		if (*p == '\0') {
			fprintf(stderr, "wintime: --detach needs a command\n");
			return 127;
		}
	}

	STARTUPINFOA si;
	PROCESS_INFORMATION pi;
	ZeroMemory(&si, sizeof si);
	si.cb = sizeof si;
	ZeroMemory(&pi, sizeof pi);

	/* --detach: bInheritHandles=FALSE + CREATE_NO_WINDOW, both required, see
	 * the header for the four-way measurement. FALSE cuts the tie to the pipe
	 * write ends msProcessSpawnSync drains to EOF (with TRUE the launch blocks
	 * for the cell's whole run); CREATE_NO_WINDOW keeps the grandchild off our
	 * console WITHOUT costing it the std handles DETACHED_PROCESS takes away —
	 * under DETACHED_PROCESS the cell's own `>` redirect produced a 0-byte log,
	 * which would silently empty every parity byte-compare. */
	if (!CreateProcessA(NULL, p, NULL, NULL,
	                    detach ? FALSE : TRUE,
	                    detach ? CREATE_NO_WINDOW : 0,
	                    NULL, NULL, &si, &pi)) {
		fprintf(stderr, "wintime: CreateProcess failed (%lu)\n", GetLastError());
		return 127;
	}
	if (detach) {
		/* Deliberately no wait: the runner polls for the cell's own sentinel
		 * file, exactly as it polls on POSIX after a `&`. */
		CloseHandle(pi.hThread);
		CloseHandle(pi.hProcess);
		return 0;
	}
	WaitForSingleObject(pi.hProcess, INFINITE);

	PROCESS_MEMORY_COUNTERS pmc;
	ZeroMemory(&pmc, sizeof pmc);
	pmc.cb = sizeof pmc;
	unsigned long long peak = 0;
	if (GetProcessMemoryInfo(pi.hProcess, &pmc, sizeof pmc)) {
		peak = (unsigned long long)pmc.PeakWorkingSetSize;
	}

	DWORD code = 0;
	GetExitCodeProcess(pi.hProcess, &code);
	CloseHandle(pi.hThread);
	CloseHandle(pi.hProcess);

	fprintf(stderr, "%20llu  maximum resident set size\n", peak);
	return (int)code;
}
