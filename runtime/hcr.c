#include "runtime/hcr.h"
#include "runtime/types.h"
#include "runtime/hcrTls.h"
#include <string.h>

#if defined(_WIN32) && defined(MS_HCR_CORE)
uint32_t msHcrTlsIndex;
#endif

typedef struct MsHcrEntry {
	struct MsHcrEntry* next;
	char* moduleId;
	MsHcrHandle handle;
} MsHcrEntry;

typedef struct MsHcrTypeEntry {
	struct MsHcrTypeEntry* next;
	char* key;
	msTypeInfo info;
} MsHcrTypeEntry;

static MsHcrEntry* msHcrEntries = NULL;
static MsHcrTypeEntry* msHcrTypes = NULL;
static int msHcrStaging = 0;

static char* msHcrCopy(const char* text, const char* what) {
	size_t length = strlen(text);
	char* copy = (char*)malloc(length + 1);
	if (copy == NULL) {
		fprintf(stderr, "HCR: cannot allocate the %s '%s'\n", what, text);
		abort();
	}
	memcpy(copy, text, length + 1);
	return copy;
}

MsHcrHandle* msHcrHandle(const char* moduleId) {
	for (MsHcrEntry* entry = msHcrEntries; entry != NULL; entry = entry->next) {
		if (strcmp(entry->moduleId, moduleId) == 0) return &entry->handle;
	}
	MsHcrEntry* entry = (MsHcrEntry*)calloc(1, sizeof(MsHcrEntry));
	if (entry == NULL) {
		fprintf(stderr, "HCR: cannot allocate the handle of module '%s'\n", moduleId);
		abort();
	}
	entry->moduleId = msHcrCopy(moduleId, "handle of module");
	entry->next = msHcrEntries;
	msHcrEntries = entry;
	return &entry->handle;
}

void msHcrPublish(const char* moduleId, void* const* table, uint32_t slotCount) {
	MsHcrHandle* handle = msHcrHandle(moduleId);
	if (msHcrStaging) {
		handle->staged = table;
		handle->stagedCount = slotCount;
		return;
	}
	handle->slotCount = slotCount;
	handle->current = table;
}

void msHcrStageBegin(void) { msHcrStaging = 1; }

void msHcrStageEnd(void) { msHcrStaging = 0; }

int32_t msHcrStaged(const char* moduleId) { return msHcrHandle(moduleId)->staged != NULL ? 1 : 0; }

void msHcrCommit(const char* moduleId) {
	MsHcrHandle* handle = msHcrHandle(moduleId);
	if (handle->staged == NULL) {
		fprintf(stderr, "HCR: module '%s' has no staged table to commit\n", moduleId);
		abort();
	}
	handle->old = handle->current;
	handle->oldCount = handle->slotCount;
	handle->slotCount = handle->stagedCount;
	handle->current = handle->staged;
	handle->staged = NULL;
	handle->stagedCount = 0;
}

void msHcrRollback(const char* moduleId) {
	MsHcrHandle* handle = msHcrHandle(moduleId);
	if (handle->old == NULL) {
		fprintf(stderr, "HCR: module '%s' has no previous table to roll back to\n", moduleId);
		abort();
	}
	handle->slotCount = handle->oldCount;
	handle->current = handle->old;
	handle->old = NULL;
	handle->oldCount = 0;
}

void msHcrDiscard(const char* moduleId) {
	MsHcrHandle* handle = msHcrHandle(moduleId);
	handle->staged = NULL;
	handle->stagedCount = 0;
}

void* msHcrTypeInfo(const char* moduleId, const char* typeName) {
	size_t moduleLength = strlen(moduleId);
	size_t typeLength = strlen(typeName);
	char* key = (char*)malloc(moduleLength + typeLength + 2);
	if (key == NULL) {
		fprintf(stderr, "HCR: cannot allocate the TypeInfo key '%s::%s'\n", moduleId, typeName);
		abort();
	}
	memcpy(key, moduleId, moduleLength);
	key[moduleLength] = ':';
	memcpy(key + moduleLength + 1, typeName, typeLength + 1);
	for (MsHcrTypeEntry* entry = msHcrTypes; entry != NULL; entry = entry->next) {
		if (strcmp(entry->key, key) == 0) {
			free(key);
			return &entry->info;
		}
	}
	MsHcrTypeEntry* entry = (MsHcrTypeEntry*)calloc(1, sizeof(MsHcrTypeEntry));
	if (entry == NULL) {
		fprintf(stderr, "HCR: cannot allocate the TypeInfo '%s'\n", key);
		abort();
	}
	entry->key = key;
	entry->next = msHcrTypes;
	msHcrTypes = entry;
	return &entry->info;
}
