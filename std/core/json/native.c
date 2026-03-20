// JSON runtime — definitions that must exist in exactly one compilation unit.
// Header (native.h) has extern declarations; this file has the definitions.

#include "native.h"

msTypeInfo JsonValue_typeInfo = { "JsonValue", MS_FALSE, NULL, NULL };
