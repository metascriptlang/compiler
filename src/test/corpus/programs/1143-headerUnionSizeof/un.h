#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef union { size_t size; int32_t a; } Corpus1143Top;
typedef struct { uint8_t r; uint8_t g; uint8_t b; } Corpus1143Rgb;
typedef union { uint8_t palette; Corpus1143Rgb rgb; uint64_t padding; } Corpus1143Value;
typedef enum { CORPUS1143_NONE = 0, CORPUS1143_RGB = 2 } Corpus1143Tag;
typedef struct { Corpus1143Tag tag; Corpus1143Value value; } Corpus1143Color;
typedef struct {
	size_t size;
	Corpus1143Color fg;
	Corpus1143Color bg;
	bool bold;
	bool italic;
	int underline;
} Corpus1143Style;
typedef struct { char c; int64_t q; char d; } Corpus1143Padded;
typedef union { Corpus1143Padded p; int32_t i; } Corpus1143PadUnion;
typedef union { char c[5]; int64_t q; } Corpus1143Mixed;
typedef union { char c[9]; int32_t i; } Corpus1143Round;
typedef union { Corpus1143PadUnion p; Corpus1143Mixed m; char c; } Corpus1143Nest;
typedef struct { size_t size; Corpus1143PadUnion p; Corpus1143Mixed m; Corpus1143Round r; Corpus1143Nest n; char tail; } Corpus1143Holder;

size_t corpus1143Size(int which);
int64_t corpus1143Fg(const Corpus1143Style* s);
