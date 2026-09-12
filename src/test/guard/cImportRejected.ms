// GUARD-CHECK-FAIL Decorators are not valid here
// A directive name without a handler must not pass through as a silent no-op;
// a decorator on a function is rejected like every other one. A guard that
// compiles clean means the name crept back into the pass-through list.

@cImport("does-not-exist.h")
function f(): int32 { return 7; }
console.log(f());
