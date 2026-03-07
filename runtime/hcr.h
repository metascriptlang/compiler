#ifndef MS_HCR_H
#define MS_HCR_H

#include <stdlib.h>
#include <stdio.h>
#include <dlfcn.h>

// ===== HCR State Handover =====
// Allocate-or-reuse pattern for module global state.
// First load: calloc + run init. Reload: reuse existing state pointer.
//
// Usage in generated code:
//   void* ModName_hcr_handover(void* old_state) {
//       MS_HCR_HANDOVER(ModName_GlobalState, ModName__Init000)
//   }

#define MS_HCR_HANDOVER(StateType, InitFn) \
    if (old_state == NULL) { \
        StateType* _gs = (StateType*)calloc(1, sizeof(StateType)); \
        InitFn(_gs); \
        return _gs; \
    } \
    return old_state;

// ===== HCR Module Handle =====

typedef struct {
    void* handle;        // dlopen handle
    void* globalState;   // heap-anchored GlobalState (survives reload)
    const char* path;    // .so/.dylib path
} MsHcrModule;

// Load or reload a module
static MsHcrModule msHcrLoad(const char* soPath, MsHcrModule* prev) {
    MsHcrModule mod;
    mod.path = soPath;
    mod.handle = dlopen(soPath, RTLD_NOW | RTLD_LOCAL);
    if (mod.handle == NULL) {
        fprintf(stderr, "HCR: dlopen failed: %s\n", dlerror());
        mod.globalState = (prev != NULL) ? prev->globalState : NULL;
        return mod;
    }
    // Find handover symbol
    typedef void* (*HandoverFn)(void*);
    HandoverFn handover = (HandoverFn)dlsym(mod.handle, "_hcr_handover");
    if (handover != NULL) {
        void* oldState = (prev != NULL) ? prev->globalState : NULL;
        mod.globalState = handover(oldState);
    } else {
        mod.globalState = (prev != NULL) ? prev->globalState : NULL;
    }
    // Close old handle (state is heap-anchored, survives close)
    if (prev != NULL && prev->handle != NULL) {
        dlclose(prev->handle);
    }
    return mod;
}

// Unload module (frees handle, NOT globalState)
static void msHcrUnload(MsHcrModule* mod) {
    if (mod->handle != NULL) {
        dlclose(mod->handle);
        mod->handle = NULL;
    }
}

#endif
