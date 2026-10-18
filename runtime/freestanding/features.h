/* Freestanding stub — the musl visibility macro the vendored libm sources include. */
#ifndef _FEATURES_H
#define _FEATURES_H
#define hidden __attribute__((__visibility__("hidden")))
#endif
