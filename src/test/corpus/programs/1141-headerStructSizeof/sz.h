#pragma once
#include <stddef.h>
#include <stdint.h>

typedef struct { size_t size; int32_t a; double b; } Corpus1141Versioned;
typedef struct { Corpus1141Versioned v; int64_t w, x, y, z; char tag; } Corpus1141Big;
typedef union { size_t size; int32_t a; } Corpus1141U;

size_t corpus1141VersionedSize(void);
size_t corpus1141BigSize(void);
size_t corpus1141USize(void);
int64_t corpus1141Accept(const Corpus1141Versioned* v);
int64_t corpus1141BigSum(Corpus1141Big b);
