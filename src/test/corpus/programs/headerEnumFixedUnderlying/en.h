#pragma once
#include <stddef.h>
#include <stdint.h>

typedef enum : int { CORPUS_ENUMFIXED_X = 0, CORPUS_ENUMFIXED_Y = 7 } CorpusEnumFixedInt;
typedef enum : unsigned char { CORPUS_ENUMFIXED_LO = 1, CORPUS_ENUMFIXED_HI = 200 } CorpusEnumFixedByte;
typedef enum CorpusEnumFixedTag : uint8_t { CORPUS_ENUMFIXED_T = 3 } CorpusEnumFixedTag;
enum CorpusEnumFixedFwd : short;
enum CorpusEnumFixedFwd : short { CORPUS_ENUMFIXED_F = 9 };
typedef enum CorpusEnumFixedFwd CorpusEnumFixedFwd;

size_t corpusEnumFixedSize(void);
