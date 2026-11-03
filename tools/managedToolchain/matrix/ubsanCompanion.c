#include <limits.h>

int matrixUbValue(int extra) {
	volatile int big = INT_MAX;
	int sum = big + extra;
	return sum;
}
