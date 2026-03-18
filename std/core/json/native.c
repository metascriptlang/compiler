// JSON runtime — definitions that must exist in exactly one compilation unit.
// Header (native.h) has extern declarations; this file has the definitions.

#include "native.h"

msTypeInfo MsJsonValue_typeInfo = { "MsJsonValue", MS_FALSE, NULL, NULL };
