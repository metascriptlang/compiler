// @xfail(raiser): raiser prints an enum member as its ordinal, `0 1` (card 2026-10-03-raiser-enum-member-prints-ordinal)
// @stdout: A B
// @exit: 0

enum K { A, B }
struct Pair<T> { a: T; b: T; }
function id<T>(x: T): T { return x; }

const e = id<K.A>(K.A);
const u: Pair<K.B> = { a: K.B, b: K.B };
console.log(e, u.a);
