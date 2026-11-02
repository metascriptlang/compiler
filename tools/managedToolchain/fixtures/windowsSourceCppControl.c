#include <math.h>
#include <stdio.h>

int main(int argc, char **argv) {
    (void)argv;
    printf("control argc=%d pow=%.0f\n", argc, pow(2.0, 9.0 + argc));
    return 0;
}
