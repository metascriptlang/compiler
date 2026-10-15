/*
 * MetaScript DateTime Runtime
 * Time primitives: wall-clock and monotonic clock.
 */

#ifndef MS_DATETIME_H
#define MS_DATETIME_H

#include "runtime/core/system.h"

/**
 * Wall-clock time in milliseconds since Unix epoch (fractional).
 * Use when comparing against external timestamps (e.g., HTTP Date header,
 * database timestamps, Lambda deadline). May jump on NTP sync or user
 * clock changes.
 */
double msTimeNow(void);

/**
 * ECMAScript TimeClip: a finite time value within +-8.64e15 truncated toward
 * zero (negative zero becomes zero); anything else is NaN.
 */
double msTimeClip(double t);

/**
 * Monotonic time in milliseconds (fractional). Never goes backward.
 * Use for elapsed-time measurement. Origin is unspecified and not
 * comparable across processes. Not affected by wall-clock adjustments.
 */
double msTimeMonotonic(void);

#endif /* MS_DATETIME_H */
