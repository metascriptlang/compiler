#include <stddef.h>

struct Pointee0;
struct Pointee0Node;

/* char **, size_t *, const char ** and struct S ** each keep their C pointee, so a strict C
   compiler takes the calls: unsigned long (size_t) is not unsigned long long (uint64_t) on macOS. */
size_t pointeeFill(char **text, size_t *cap);
long strtol(const char *s, char **end, int base);
long pointeeGetline(char **line, size_t *cap);
const char **pointeeList(void);
int pointeeNames(const char **names, size_t *count);
int pointeeNode(struct Pointee0Node **out);
int pointeeNodeValue(struct Pointee0Node *node);
void pointeeNodeFree(struct Pointee0Node *node);
