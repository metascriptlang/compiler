#include <float.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <math.h>

#ifdef __GLIBC__
#error "musl profile compiled against glibc headers"
#endif

static atomic_int counter;
static _Thread_local int local = 7;

static void *work(void *arg) {
    local = 100;
    atomic_fetch_add(&counter, *(int *)arg);
    return NULL;
}

int main(void) {
    int *p = malloc(4 * sizeof(int));
    wchar_t wide = L'x';
    pthread_t thread;
    volatile double two = 2.0, ten = 10.0;
    if (!p) return 1;
    for (int i = 0; i < 4; i++) p[i] = i * i;
    if (pthread_create(&thread, NULL, work, &p[3]) != 0) {
        free(p);
        return 2;
    }
    if (pthread_join(thread, NULL) != 0) return 3;
    printf("ok sum=%d sqrt=%.3f wide=%d eps=%d tls=%d pow=%.0f\n", atomic_load(&counter), sqrt(two), (int)wide,
           DBL_EPSILON < 1e-10, local, pow(two, ten));
    free(p);
    return 0;
}
