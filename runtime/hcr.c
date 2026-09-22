#include "runtime/hcr.h"
#include <string.h>

typedef struct MsHcrEntry {
	struct MsHcrEntry* next;
	char* moduleId;
	MsHcrHandle handle;
} MsHcrEntry;

static MsHcrEntry* msHcrEntries = NULL;

MsHcrHandle* msHcrHandle(const char* moduleId) {
	for (MsHcrEntry* entry = msHcrEntries; entry != NULL; entry = entry->next) {
		if (strcmp(entry->moduleId, moduleId) == 0) return &entry->handle;
	}
	MsHcrEntry* entry = (MsHcrEntry*)calloc(1, sizeof(MsHcrEntry));
	size_t idLength = strlen(moduleId);
	char* id = entry != NULL ? (char*)malloc(idLength + 1) : NULL;
	if (id == NULL) {
		fprintf(stderr, "HCR: cannot allocate the handle of module '%s'\n", moduleId);
		abort();
	}
	memcpy(id, moduleId, idLength + 1);
	entry->moduleId = id;
	entry->next = msHcrEntries;
	msHcrEntries = entry;
	return &entry->handle;
}

void msHcrPublish(const char* moduleId, void* const* table, uint32_t slotCount) {
	MsHcrHandle* handle = msHcrHandle(moduleId);
	handle->slotCount = slotCount;
	handle->current = table;
}
