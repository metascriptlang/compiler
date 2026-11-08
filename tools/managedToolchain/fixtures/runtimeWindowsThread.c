#include <pthread.h>
#include <stdio.h>

static void *work(void *argument) {
    *(int *)argument = 42;
    return NULL;
}

int main(void) {
    pthread_t thread;
    int value = 0;
    if (pthread_create(&thread, NULL, work, &value) != 0) return 1;
    if (pthread_join(thread, NULL) != 0) return 2;
    printf("ok thread=%d\n", value);
    return value == 42 ? 0 : 3;
}
