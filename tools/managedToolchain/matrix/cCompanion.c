#include <math.h>
#include <stdlib.h>

int matrixCValue(void) {
	int *values = malloc(4 * sizeof(int));
	for (int i = 0; i < 4; i++) values[i] = i * i;
	int sum = values[0] + values[1] + values[2] + values[3] + (int)(sqrt(2.0) * 1000);
	free(values);
	return sum;
}
