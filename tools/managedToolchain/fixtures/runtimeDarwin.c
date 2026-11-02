#include <stdio.h>
#include <pthread.h>
#include <math.h>
static void* f(void* a){ printf("%g\n", pow(2.0, 10)); return 0; }
int main(void){ pthread_t t; pthread_create(&t,0,f,0); pthread_join(t,0); puts("hello darwin"); return 0; }
