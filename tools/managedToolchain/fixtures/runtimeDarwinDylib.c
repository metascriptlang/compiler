#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <math.h>

static void *work(void *arg) {
    *(int *)arg += 1;
    return NULL;
}

int addNumbers(int a, int b) {
    int *p = malloc(sizeof(int));
    pthread_t thread;
    *p = a;
    pthread_create(&thread, NULL, work, p);
    pthread_join(thread, NULL);
    printf("add sqrt=%.3f\n", sqrt(2.0));
    a = *p - 1 + b;
    free(p);
    return a;
}
