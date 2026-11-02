#include <math.h>
#include <stdio.h>

/* Every input comes from argc or a volatile, so nothing here folds at compile time: each call below must reach
   the runtime's own pow, fmod, nan and nanl, including when link-time optimization sees the whole program. */
int main(int argc, char **argv) {
    volatile double two = argc + 1.0;
    volatile char tag = argc > 100 ? 'x' : '\0';
    char tags[2] = {tag, '\0'};
    double power = pow(two, 10.0);
    double remainder = fmod(two * 5.0, 4.0);
    double quiet = nan(tags);
    long double quietLong = nanl(tags);
    (void)argv;
    printf("hello windows-source\n");
    printf("math pow=%d fmod=%d nan=%d nanl=%d isnan=%d\n", (int)power, (int)remainder, isnan(quiet) ? 1 : 0,
           isnan(quietLong) ? 1 : 0, (!isnan(two) && isnan(quiet + power)) ? 1 : 0);
    return 0;
}
