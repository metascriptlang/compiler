#include "../examples/hcrProbe/hostCalls.h"
#include <unistd.h>

typedef int32_t (*ProbeFn)(void);

typedef struct {
	void* handle;
	void* state;
	const char* path;
} HcrModule;

static int hcrLoadInitial(HcrModule* module, const char* path, const char* probe) {
	if (!hcrProbeOpenCore(path)) {
		fprintf(stderr, "HCR: core load or symbol resolution failed for %s\n", path);
		return 0;
	}
	void* handle = msHcrImageOpen(path);
	if (handle == NULL) {
		fprintf(stderr, "dlopen: %s\n", msHcrImageFailure());
		return 0;
	}
	if (!hcrProbeValidate(handle, probe)) {
		fprintf(stderr, "HCR: required image symbol or variable metadata missing in %s\n", path);
		msHcrImageClose(handle);
		return 0;
	}
	if (hcrProbeCallDatInit(handle) || hcrProbeCallInit(handle)) {
		fprintf(stderr, "HCR: initial initialization failed for %s\n", path);
		return 0;
	}
	*module = (HcrModule){handle, hcrProbeState(handle), path};
	return 1;
}

static int hcrReject(void* handle, const char* path, const char* reason) {
	if (handle != NULL) msHcrImageClose(handle);
	printf("HCR-PROBE rejected %s (%s)\n", path, reason);
	return 0;
}

static int hcrTryReload(HcrModule* current, const char* imagePath, const char* path, const char* probe) {
	void* handle = msHcrImageOpen(imagePath);
	if (handle == NULL) {
		fprintf(stderr, "dlopen: %s\n", msHcrImageFailure());
		return hcrReject(NULL, path, "dlopen");
	}
	if (!hcrProbeValidate(handle, probe)) return hcrReject(handle, path, "dlsym");
	if (!hcrProbeSameModule(current->handle, handle)) return hcrReject(handle, path, "identity");
	if (!hcrProbeSameTypes(current->handle, handle)) {
		fprintf(stderr, "HCR: restart required for changed type layout in %s\n", path);
		return hcrReject(handle, path, "layout");
	}
	hcrProbeStageBegin();
	int32_t failed = hcrProbeCallDatInit(handle);
	hcrProbeStageEnd();
	if (failed || !hcrProbeStaged(handle)) {
		hcrProbeDiscard(handle);
		return hcrReject(handle, path, "init");
	}
	hcrProbeCommit(handle);
	if (hcrProbeCallInit(handle)) {
		hcrProbeRollback(handle);
		return hcrReject(NULL, path, "init");
	}
	hcrProbeFinalize(handle);
	*current = (HcrModule){handle, hcrProbeState(handle), path};
	printf("HCR-PROBE reloaded %s state=%p\n", path, current->state);
	return 1;
}

static int hcrPrintCall(const HcrModule* module, const char* symbol) {
	ProbeFn fn = (ProbeFn)msHcrImageSymbol(module->handle, symbol);
	if (fn == NULL) {
		fprintf(stderr, "HCR: missing probe %s in %s\n", symbol, module->path);
		return 0;
	}
	printf("HCR-PROBE call %s -> %d\n", module->path, fn());
	return 1;
}

static int runProbe(int argc, char** argv) {
	if ((argc - 2) % 2 != 0) return 1;
	HcrModule module = {0};
	if (!hcrLoadInitial(&module, argv[3], argv[2])) return 1;
	printf("HCR-PROBE loaded %s state=%p\n", module.path, module.state);
	const char* currentSymbol = argv[2];
	if (!hcrPrintCall(&module, currentSymbol)) return 1;
	for (int i = 4; i + 1 < argc; i += 2) {
		if (hcrTryReload(&module, argv[i + 1], argv[i + 1], argv[i])) currentSymbol = argv[i];
		if (!hcrPrintCall(&module, currentSymbol)) return 1;
	}
	return 0;
}

static int hcrCopyCandidate(const char* path, char* copy, size_t capacity, unsigned generation) {
	int length = snprintf(copy, capacity, "%s.reload.%ld.%u%s", path, (long)getpid(), generation, MS_HCR_IMAGE_EXT);
	if (length < 0 || (size_t)length >= capacity) return 0;
	FILE* input = fopen(path, "rb");
	if (input == NULL) return 0;
	FILE* output = fopen(copy, "wb");
	if (output == NULL) { fclose(input); return 0; }
	char buffer[65536];
	size_t size;
	int ok = 1;
	while ((size = fread(buffer, 1, sizeof(buffer), input)) != 0) {
		if (fwrite(buffer, 1, size, output) != size) { ok = 0; break; }
	}
	if (ferror(input)) ok = 0;
	fclose(input);
	if (fclose(output) != 0) ok = 0;
	if (!ok) unlink(copy);
	return ok;
}

int main(int argc, char** argv) {
	if (argc >= 4 && strcmp(argv[1], "--probe") == 0) return runProbe(argc, argv);
	if (argc != 2) {
		fprintf(stderr, "Usage: hcrHost <module.so>\n"
			"       hcrHost --probe <sym1> <gen1.so> [<sym2> <gen2.so> ...]\n");
		return 1;
	}
	HcrModule module = {0};
	if (!hcrLoadInitial(&module, argv[1], NULL)) return 1;
	printf("Module loaded. State: %p\n", module.state);
	printf("Press Enter to reload, 'q' to quit.\n");
	char line[256];
	unsigned generation = 0;
	while (fgets(line, sizeof(line), stdin)) {
		if (line[0] == 'q') break;
		char copy[4096];
		if (!hcrCopyCandidate(argv[1], copy, sizeof(copy), ++generation)) {
			fprintf(stderr, "HCR: cannot copy candidate %s; current retained\n", argv[1]);
			continue;
		}
		hcrTryReload(&module, copy, argv[1], NULL);
		unlink(copy);
	}
	return 0;
}
