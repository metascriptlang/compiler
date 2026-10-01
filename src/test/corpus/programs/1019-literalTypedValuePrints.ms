// Parity program — a value whose type is a string or boolean literal type
// (a literal type argument, an explicit `<true>`) prints its value, in
// console.log and in a template string alike.
//
// @stdout: x true false x-true-false
// @exit: 0

struct Pair<T> { a: T; b: T; }
function id<T>(x: T): T { return x; }

const p: Pair<"x"> = { a: "x", b: "x" };
const t = id<true>(true);
const f: Pair<false> = { a: false, b: false };
console.log(p.a, t, f.a, `${p.b}-${t}-${f.b}`);
