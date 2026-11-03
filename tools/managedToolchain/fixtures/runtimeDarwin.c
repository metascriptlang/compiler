#include <stdio.h>
#include <pthread.h>
#include <math.h>
static void* f(void* a){ printf("%g\n", pow(2.0, 10)); return 0; }
static unsigned __int128 divide(unsigned __int128 a, unsigned __int128 b){ return a / b; }
int main(void){ volatile unsigned long x = 7; pthread_t t; pthread_create(&t,0,f,0); pthread_join(t,0);
  printf("%lu\n", (unsigned long)divide((unsigned __int128)x << 70, 3 << 3)); puts("hello darwin"); return 0; }
