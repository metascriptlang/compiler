#include <stdint.h>

__attribute__((import_module("host"), import_name("value")))
int32_t hostValue(int32_t key);
__attribute__((import_module("host"), import_name("finish")))
void hostFinish(int32_t value);
