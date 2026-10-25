// SELFTEST-RED none marked GUARD-REFUSED
// GUARD-CHECK-FAIL Decorators are not valid here

@cImport("one.h")
function first(): int32 { return 7; }
@cImport("two.h")
function second(): int32 { return 8; }
console.log(first() + second());
