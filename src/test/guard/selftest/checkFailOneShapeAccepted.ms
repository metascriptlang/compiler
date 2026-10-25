// SELFTEST-RED that shape compiles
// GUARD-CHECK-FAIL Decorators are not valid here

@cImport("one.h") // GUARD-REFUSED
function refused(): int32 { return 7; }
function accepted(): int32 { return 8; } // GUARD-REFUSED
console.log(refused() + accepted());
