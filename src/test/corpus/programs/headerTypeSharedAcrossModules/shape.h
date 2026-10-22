#include <stdint.h>
typedef struct ShapeImpl* Shape;
typedef struct { int32_t w; int32_t h; } Size;
typedef enum { SHAPE_SQUARE = 0, SHAPE_ROUND = 1 } ShapeKind;
