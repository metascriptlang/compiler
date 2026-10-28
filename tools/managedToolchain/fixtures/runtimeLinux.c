#include <float.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <math.h>

static atomic_int counter;

static void *work(void *arg) {
    atomic_fetch_add(&counter, *(int *)arg);
    return NULL;
}

int main(void) {
    int *p = malloc(4 * sizeof(int));
    wchar_t wide = L'x';
    pthread_t thread;
    for (int i = 0; i < 4; i++) p[i] = i * i;
    pthread_create(&thread, NULL, work, &p[3]);
    pthread_join(thread, NULL);
    printf("ok sum=%d sqrt=%.3f wide=%d eps=%d\n", atomic_load(&counter), sqrt(2.0), (int)wide,
           DBL_EPSILON < 1e-10);
    free(p);
    return 0;
}
