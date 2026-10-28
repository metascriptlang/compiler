#pragma once
#include <stddef.h>
#include <stdint.h>

typedef enum : int { CORPUS_ENUMFIXED_X = 0, CORPUS_ENUMFIXED_Y = 7 } CorpusEnumFixedInt;
typedef enum : unsigned int { CORPUS_ENUMFIXED_LO = 1, CORPUS_ENUMFIXED_HI = 200 } CorpusEnumFixedUnsigned;
typedef enum CorpusEnumFixedTag : int32_t { CORPUS_ENUMFIXED_T = 3 } CorpusEnumFixedTag;
enum CorpusEnumFixedFwd : int;
enum CorpusEnumFixedFwd : int { CORPUS_ENUMFIXED_F = 9 };
typedef enum CorpusEnumFixedFwd CorpusEnumFixedFwd;

size_t corpusEnumFixedSize(void);
