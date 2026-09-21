// HCR Host — loads a MetaScript .so/.dylib module, supports reload
//
// Interactive usage: hcrHost <module.so>
//   Press Enter to reload, 'q' to quit.
//
// Probe usage: hcrHost --probe <symbol> <gen1.so> <gen2.so> [...]
//   Single-image reload contract, driven over generation paths:
//   loads gen1, then for each further path loads the CANDIDATE while the
//   current generation stays mapped, validates the state handover, and
//   publishes only on success. A rejected candidate never disturbs current.
//
// The host calls three symbols from the loaded module:
//   _hcr_handover(old_state) — allocates or reuses GlobalState; NULL rejects
//                              the candidate (incompatible layout change)
//   DatInit000()             — data/type initialization (every generation)
//   Init000()                — user top-level code (first load only)
//
// Probe output lines (stable prefixes, asserted by run.sh):
//   HCR-PROBE loaded <file> state=<ptr>
//   HCR-PROBE call <file> -> <value>
//   HCR-PROBE reloaded <file> state=<ptr>
//   HCR-PROBE rejected <file> (layout|dlopen|dlsym)
// The rejected-generation call line repeats the CURRENT file name: it proves
// the running image still answers.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dlfcn.h>

typedef void* (*HandoverFn)(void*);
typedef void (*InitFn)(void);
typedef int (*ProbeFn)(void);

typedef struct {
    void* handle;
    void* state;
    const char* path;
} HcrModule;

static HcrModule hcrLoad(const char* path, void* oldState) {
    HcrModule m = {0, 0, path};
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

// Load candidate without disturbing current. Returns 1 when the candidate was
// published (current updated); 0 when it was rejected and current is intact.
static int hcrTryReload(HcrModule* current, const char* path) {
    HcrModule cand = {0, 0, path};
    cand.handle = dlopen(path, RTLD_NOW);
    if (!cand.handle) {
        fprintf(stderr, "dlopen: %s\n", dlerror());
        printf("HCR-PROBE rejected %s (dlopen)\n", path);
        return 0;
    }

    HandoverFn handover = (HandoverFn)dlsym(cand.handle, "_hcr_handover");
    if (!handover) {
        fprintf(stderr, "dlsym(_hcr_handover): %s\n", dlerror());
        dlclose(cand.handle);
        printf("HCR-PROBE rejected %s (dlsym)\n", path);
        return 0;
    }

    // Rejected inside handover: incompatible _GlobalState layout. The module
    // already printed the restart-required diagnostic on stderr.
    cand.state = handover(current->state);
    if (!cand.state) {
        dlclose(cand.handle);
        printf("HCR-PROBE rejected %s (layout)\n", path);
        return 0;
    }

    InitFn datInit = (InitFn)dlsym(cand.handle, "DatInit000");
    if (datInit) datInit();
    // Init000 stays first-load only: global initializers must not rerun over
    // live state.

    // Publish. The previous generation stays mapped: unloading code another
    // frame may still reference is not ours to decide here.
    *current = cand;
    printf("HCR-PROBE reloaded %s state=%p\n", path, current->state);
    return 1;
}

static int runProbe(int argc, char** argv) {
    // argv: --probe sym1 gen1 [sym2 gen2 ...]; one pair per generation. Each
    // generation exports a path-mangled symbol, so the callable is re-resolved
    // from the CURRENT handle after every step — the single-image stand-in for
    // what the module vtable does in the cross-module design.
    HcrModule mod = hcrLoad(argv[3], 0);
    if (!mod.handle) return 1;
    printf("HCR-PROBE loaded %s state=%p\n", mod.path, mod.state);

    const char* curSym = argv[2];
    ProbeFn fn = (ProbeFn)dlsym(mod.handle, curSym);
    if (!fn) {
        fprintf(stderr, "dlsym(%s): %s\n", curSym, dlerror());
        return 1;
    }
    printf("HCR-PROBE call %s -> %d\n", mod.path, fn());

    for (int i = 4; i + 1 < argc; i += 2) {
        if (hcrTryReload(&mod, argv[i + 1])) curSym = argv[i];
        fn = (ProbeFn)dlsym(mod.handle, curSym);
        if (!fn) {
            fprintf(stderr, "dlsym(%s): %s\n", curSym, dlerror());
            return 1;
        }
        printf("HCR-PROBE call %s -> %d\n", mod.path, fn());
    }
    return 0;
}

int main(int argc, char** argv) {
    if (argc >= 4 && strcmp(argv[1], "--probe") == 0) {
        return runProbe(argc, argv);
    }
    if (argc < 2) {
        fprintf(stderr, "Usage: hcrHost <module.so>\n"
                        "       hcrHost --probe <sym1> <gen1.so> [<sym2> <gen2.so> ...]\n");
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
