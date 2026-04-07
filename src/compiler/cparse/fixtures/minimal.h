/* cparse fixture: minimal.h
 * Hand-written header exercising every construct we claim to support in v1.
 * Serves as the first acceptance test — if this parses and the emitted MS
 * matches expectations, v1 is feature-complete for the baseline scope.
 */
#ifndef CPARSE_MINIMAL_H
#define CPARSE_MINIMAL_H

#include <stdint.h>

/* Simple typedefs */
typedef int MyInt;
typedef const char *CString;
typedef int (*CompareFn)(const void *, const void *);

/* Anonymous struct with trailing typedef name */
typedef struct {
    int32_t id;
    const char *name;
} Person;

/* Named struct with self-referential pointer */
typedef struct Node {
    int32_t value;
    struct Node *next;
} Node;

/* Union */
typedef union {
    int32_t i;
    float f;
} IntOrFloat;

/* Enum with computed values */
typedef enum {
    FLAG_NONE  = 0,
    FLAG_READ  = 1 << 0,
    FLAG_WRITE = 1 << 1,
    FLAG_EXEC  = 1 << 2,
    FLAG_ALL   = FLAG_READ | FLAG_WRITE | FLAG_EXEC,
} Flags;

/* Extern function prototypes */
extern int add(int a, int b);
extern void  log_message(const char *fmt, ...);
extern Person *person_create(const char *name, int32_t id);
extern void person_free(Person *p);

/* Extern variable */
extern int global_counter;

/* Static const (should emit as constant) */
static const int MAX_ITEMS = 256;

#endif /* CPARSE_MINIMAL_H */
