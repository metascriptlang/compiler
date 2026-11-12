#include "stackSmash.h"

struct MatrixSlack {
	long a, b, c, d, e, f;
};

__attribute__((noinline)) static void matrixFill(volatile char *at, int count) {
	for (int i = 0; i < count; i++) at[i] = 'A';
}

/* The slack is declared first and holds no array: an unprotected -O0 frame keeps it above the buffer, so the
 * bytes past the buffer land in it; a protected frame puts the buffer, its only array, next to the guard. */
int matrixSmash(int extra) {
	volatile struct MatrixSlack slack;
	char buffer[16];
	slack.a = extra;
	matrixFill(buffer, 16 + extra);
	return buffer[0];
}
