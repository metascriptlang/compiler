#include <dlfcn.h>
#include <stdio.h>

typedef int (*Sum)(int);
typedef int (*Destroyed)(void);

static int fail(int code, const char *what) {
    const char *reason = dlerror();
    fprintf(stderr, "host: %s%s%s\n", what, reason ? ": " : "", reason ? reason : "");
    return code;
}

int main(int argc, char **argv) {
    if (argc != 2) return fail(2, "usage: host SHARED_OBJECT");
    void *library = dlopen(argv[1], RTLD_NOW);
    if (!library) return fail(3, "dlopen");
    Sum sum = (Sum)dlsym(library, "cppSum");
    if (!sum) return fail(4, "cppSum");
    Destroyed destroyed = (Destroyed)dlsym(library, "cppDestroyed");
    if (!destroyed) return fail(4, "cppDestroyed");
    if (sum(3) != 6 || destroyed() != 1) return fail(5, "cppSum(3) is not 6 with one destructor run");
    if (sum(-1) != -1 || destroyed() != 2) return fail(6, "cppSum(-1) did not throw, catch and destroy its guard");
    if (dlclose(library) != 0) return fail(7, "dlclose");
    puts("host ok");
    return 0;
}
