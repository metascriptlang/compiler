#include <pthread.h>
#include <stdio.h>

static int shared;

static void *work(void *arg) {
    (void)arg;
    for (int i = 0; i < 100000; i++) shared++;
    return NULL;
}

int main(void) {
    pthread_t a, b;
    if (pthread_create(&a, NULL, work, NULL) != 0 || pthread_create(&b, NULL, work, NULL) != 0) return 2;
    pthread_join(a, NULL);
    pthread_join(b, NULL);
    printf("%d\n", shared);
    return 0;
}
