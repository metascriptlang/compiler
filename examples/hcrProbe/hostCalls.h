#ifndef MS_HCR_PROBE_HOST_CALLS_H
#define MS_HCR_PROBE_HOST_CALLS_H

#include "../../runtime/hcr.h"
#include <string.h>

typedef const char* (*HcrProbeTextFn)(void);
typedef const char* const* (*HcrProbeListFn)(void);

typedef struct {
	void* handle;
	void (*coreInit)(void);
	void (*stageBegin)(void);
	void (*stageEnd)(void);
	int32_t (*staged)(const char*);
	void (*commit)(const char*);
	void (*rollback)(const char*);
	void (*discard)(const char*);
	void (*finalize)(const char*);
	MsHcrCell* (*bind)(const char*, const char*, const char*);
	int32_t (*callInitStatus)(void*);
} HcrProbeCore;

static HcrProbeCore hcrProbeCore;

static inline int32_t hcrProbeOpenCore(const char* imagePath) {
	if (hcrProbeCore.handle != NULL) return 1;
	const char* slash = strrchr(imagePath, '/');
	const char* backslash = strrchr(imagePath, '\\');
	if (backslash != NULL && (slash == NULL || backslash > slash)) slash = backslash;
	const char* dot = strrchr(imagePath, '.');
	if (dot == NULL || (slash != NULL && dot < slash)) dot = imagePath + strlen(imagePath);
	size_t prefix = (size_t)(dot - imagePath);
	char path[4096];
	if (prefix + sizeof(".core" MS_HCR_IMAGE_EXT) > sizeof(path)) return 0;
	memcpy(path, imagePath, prefix);
	memcpy(path + prefix, ".core" MS_HCR_IMAGE_EXT, sizeof(".core" MS_HCR_IMAGE_EXT));
	void* handle = msHcrImageOpen(path);
	if (handle == NULL) return 0;
	HcrProbeCore core = {0};
	core.handle = handle;
	core.coreInit = (void (*)(void))msHcrImageSymbol(handle, "msHcrCoreInit");
	core.stageBegin = (void (*)(void))msHcrImageSymbol(handle, "msHcrStageBegin");
	core.stageEnd = (void (*)(void))msHcrImageSymbol(handle, "msHcrStageEnd");
	core.staged = (int32_t (*)(const char*))msHcrImageSymbol(handle, "msHcrStaged");
	core.commit = (void (*)(const char*))msHcrImageSymbol(handle, "msHcrCommit");
	core.rollback = (void (*)(const char*))msHcrImageSymbol(handle, "msHcrRollback");
	core.discard = (void (*)(const char*))msHcrImageSymbol(handle, "msHcrDiscard");
	core.finalize = (void (*)(const char*))msHcrImageSymbol(handle, "msHcrFinalize");
	core.bind = (MsHcrCell* (*)(const char*, const char*, const char*))msHcrImageSymbol(handle, "msHcrBind");
	core.callInitStatus = (int32_t (*)(void*))msHcrImageSymbol(handle, "msHcrInvokeInit");
	if (core.coreInit == NULL || core.stageBegin == NULL || core.stageEnd == NULL ||
		core.staged == NULL || core.commit == NULL || core.rollback == NULL ||
		core.discard == NULL || core.finalize == NULL || core.bind == NULL ||
		core.callInitStatus == NULL) {
		msHcrImageClose(handle);
		return 0;
	}
	hcrProbeCore = core;
	hcrProbeCore.coreInit();
	return 1;
}

static inline const char* hcrProbeModuleId(void* handle) {
	return ((HcrProbeTextFn)msHcrImageSymbol(handle, "HcrModuleId000"))();
}

static inline const char* const* hcrProbeMetadata(void* handle, const char* name) {
	return ((HcrProbeListFn)msHcrImageSymbol(handle, name))();
}

static inline int32_t hcrProbeValidate(void* handle, const char* probe) {
	const char* required[] = {
		"DatInit000", "Init000", "HcrModuleId000", "HcrFunctions000",
		"HcrVariables000", "HcrBindings000", "HcrImports000", "HcrTypeKeys000"
	};
	for (size_t i = 0; i < sizeof(required) / sizeof(required[0]); ++i) {
		if (msHcrImageSymbol(handle, required[i]) == NULL) return 0;
	}
	if (probe != NULL && probe[0] != '\0' && msHcrImageSymbol(handle, probe) == NULL) return 0;
	const char* id = hcrProbeModuleId(handle);
	if (id == NULL || id[0] == '\0') return 0;
	const char* const* variables = hcrProbeMetadata(handle, "HcrVariables000");
	if (variables == NULL || variables[0] == NULL || variables[1] == NULL) return 0;
	return 1;
}

static inline int32_t hcrProbeSameModule(void* current, void* candidate) {
	return strcmp(hcrProbeModuleId(current), hcrProbeModuleId(candidate)) == 0;
}

static inline int32_t hcrProbeSameTypes(void* current, void* candidate) {
	const char* const* old = hcrProbeMetadata(current, "HcrTypeKeys000");
	const char* const* next = hcrProbeMetadata(candidate, "HcrTypeKeys000");
	for (size_t i = 0; old[i] != NULL; i += 2) {
		int found = 0;
		for (size_t j = 0; next[j] != NULL; j += 2) {
			if (strcmp(old[i], next[j]) != 0) continue;
			if (strcmp(old[i + 1], next[j + 1]) != 0) return 0;
			found = 1;
			break;
		}
		if (!found) return 0;
	}
	return 1;
}

static inline int32_t hcrProbeCallDatInit(void* handle) {
	return hcrProbeCore.callInitStatus(msHcrImageSymbol(handle, "DatInit000"));
}

static inline int32_t hcrProbeCallInit(void* handle) {
	return hcrProbeCore.callInitStatus(msHcrImageSymbol(handle, "Init000"));
}

static inline void* hcrProbeState(void* handle) {
	const char* const* variables = hcrProbeMetadata(handle, "HcrVariables000");
	return hcrProbeCore.bind(hcrProbeModuleId(handle), variables[0], variables[1])->current;
}

static inline void hcrProbeStageBegin(void) { hcrProbeCore.stageBegin(); }
static inline void hcrProbeStageEnd(void) { hcrProbeCore.stageEnd(); }
static inline int32_t hcrProbeStaged(void* handle) { return hcrProbeCore.staged(hcrProbeModuleId(handle)); }
static inline void hcrProbeCommit(void* handle) { hcrProbeCore.commit(hcrProbeModuleId(handle)); }
static inline void hcrProbeRollback(void* handle) { hcrProbeCore.rollback(hcrProbeModuleId(handle)); }
static inline void hcrProbeDiscard(void* handle) { hcrProbeCore.discard(hcrProbeModuleId(handle)); }
static inline void hcrProbeFinalize(void* handle) { hcrProbeCore.finalize(hcrProbeModuleId(handle)); }

#endif
