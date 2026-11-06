/*
 * msDeclassify marks a value computed from a secret as public where the caller is about to reveal it anyway (a tag
 * or padding verdict, a plaintext length). Only a build with -DMS_CT_VALIDATION (tools/crypto/ctTaint.sh) turns it
 * into a Valgrind memcheck request, so the taint run reports only the branches and indexes nobody meant to reveal;
 * every other build expands it to nothing.
 */

#ifndef MS_CRYPTO_CT_VALIDATION_H
#define MS_CRYPTO_CT_VALIDATION_H

#ifdef MS_CT_VALIDATION
#include <valgrind/memcheck.h>
#define msDeclassify(ptr, len) ((void)VALGRIND_MAKE_MEM_DEFINED((ptr), (len)))
#else
#define msDeclassify(ptr, len) ((void)0)
#endif

#endif
