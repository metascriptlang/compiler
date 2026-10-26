#include <stdlib.h>
#include <string.h>
#include "pointee.h"

struct Pointee0Node { int v; };

size_t pointeeFill(char **text, size_t *cap) {
	static char line[] = "pointee";
	*text = line;
	*cap = sizeof(line);
	return strlen(line);
}

static const char *list[] = { "a", "bc" };

const char **pointeeList(void) { return list; }

int pointeeNames(const char **names, size_t *count) {
	*count = 2;
	return (int)strlen(names[1]);
}

int pointeeNode(struct Pointee0Node **out) {
	*out = malloc(sizeof(struct Pointee0Node));
	(*out)->v = 5;
	return 0;
}
int pointeeNodeValue(struct Pointee0Node *node) { return node->v; }
void pointeeNodeFree(struct Pointee0Node *node) { free(node); }
