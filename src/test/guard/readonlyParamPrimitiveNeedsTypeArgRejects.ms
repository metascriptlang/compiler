// A type parameter read only through Readonly<T> is not inferred from a primitive argument
//
// INVARIANT: inference through a homomorphic mapped type rebuilds the argument's members; a
//   boolean, string or number has none to rebuild, so the call names the type argument instead
//   of inferring one.
//
// WHAT IT CATCHES: a primitive argument silently binding T through Readonly<T>, or the refusal
//   losing the explicit form it names.
//
// RED MEANS: one of the three refusals stopped firing or changed its text.
//
// GUARD-JS
// GUARD-CHECK-FAIL cannot infer T from a boolean through Readonly<T>; write flag<boolean>(…)
// GUARD-CHECK-FAIL cannot infer T from a string through Readonly<T>; write label<string>(…)
// GUARD-CHECK-FAIL cannot infer T from a number through Readonly<T>; write amount<number>(…)

function flag<T>(x: Readonly<T>): int32 { return 1; }
function label<T>(x: Readonly<T>): int32 { return 2; }
function amount<T>(x: Readonly<T>): int32 { return 3; }

const n: number = 1.5;
console.log(flag(true), label("s"), amount(n));
