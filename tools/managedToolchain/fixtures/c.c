#include <stdio.h>
#include <stdlib.h>
#include <math.h>
int main(void){ int*p=malloc(4*sizeof(int)); for(int i=0;i<4;i++)p[i]=i*i; printf("c ok sum=%d sqrt=%.3f\n",p[0]+p[1]+p[2]+p[3],sqrt(2.0)); free(p); return 0; }
