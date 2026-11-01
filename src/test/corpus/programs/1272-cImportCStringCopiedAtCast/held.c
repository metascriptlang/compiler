#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "held.h"

static char shared[64];

const char *corpus1272Name(const char *s) {
	snprintf(shared, sizeof shared, "name:%s", s);
	return shared;
}

char *corpus1272Make(const char *s) {
	char *p = malloc(strlen(s) + 1);
	strcpy(p, s);
	return p;
}

void corpus1272Free(char *p) { free(p); }
