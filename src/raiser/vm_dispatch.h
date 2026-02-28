#ifndef RAISER_DISPATCH_H
#define RAISER_DISPATCH_H

// Forward declare — full definition comes later in _common.h
typedef struct RaiserVM RaiserVM;

// Computed goto dispatch for Raiser VM.
// Implementation in vm_dispatch.c (auto-compiled by @include).
// Returns: 0.0 = halted, 1.0 = unhandled opcode (vm->ip set)
double raiser_dispatch_impl(RaiserVM* vm);

#endif
