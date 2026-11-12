#ifndef MS_EXPORT_H
#define MS_EXPORT_H

#if !defined(MS_LIB_BUILD)
#define MS_LIB_EXPORT
#elif defined(_WIN32)
#define MS_LIB_EXPORT __declspec(dllexport)
#else
#define MS_LIB_EXPORT __attribute__((visibility("default")))
#endif

#endif /* MS_EXPORT_H */
