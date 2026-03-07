// HCR Host — loads a MetaScript .so/.dylib module, supports reload
//
// Usage: hcrHost <module.so>
//   Press Enter to reload, 'q' to quit.
//
// The host calls three symbols from the loaded module:
//   _hcr_handover(old_state) — allocates or reuses GlobalState
//   DatInit000()             — data/type initialization
//   Init000()                — user top-level code (first load only)

#include <stdio.h>
#include <stdlib.h>
#include <dlfcn.h>

typedef void* (*HandoverFn)(void*);
typedef void (*InitFn)(void);

typedef struct {
    void* handle;
    void* state;
} HcrModule;

static HcrModule hcrLoad(const char* path, void* oldState) {
    HcrModule m = {0, 0};
    m.handle = dlopen(path, RTLD_NOW);
    if (!m.handle) {
        fprintf(stderr, "dlopen: %s\n", dlerror());
        return m;
    }

    HandoverFn handover = (HandoverFn)dlsym(m.handle, "_hcr_handover");
    if (!handover) {
        fprintf(stderr, "dlsym(_hcr_handover): %s\n", dlerror());
        dlclose(m.handle);
        m.handle = 0;
        return m;
    }

    m.state = handover(oldState);

    InitFn datInit = (InitFn)dlsym(m.handle, "DatInit000");
    if (datInit) datInit();

    if (oldState == 0) {
        InitFn init = (InitFn)dlsym(m.handle, "Init000");
        if (init) init();
    }

    return m;
}

int main(int argc, char** argv) {
    if (argc < 2) {
        fprintf(stderr, "Usage: hcrHost <module.so>\n");
        return 1;
    }

    HcrModule mod = hcrLoad(argv[1], 0);
    if (!mod.handle) return 1;

    printf("Module loaded. State: %p\n", mod.state);
    printf("Press Enter to reload, 'q' to quit.\n");

    char buf[256];
    while (fgets(buf, sizeof(buf), stdin)) {
        if (buf[0] == 'q') break;
        printf("Reloading %s...\n", argv[1]);
        void* oldState = mod.state;
        if (mod.handle) dlclose(mod.handle);
        mod = hcrLoad(argv[1], oldState);
        if (!mod.handle) {
            fprintf(stderr, "Reload failed\n");
            return 1;
        }
        printf("Reloaded. State: %p\n", mod.state);
    }

    if (mod.handle) dlclose(mod.handle);
    return 0;
}
