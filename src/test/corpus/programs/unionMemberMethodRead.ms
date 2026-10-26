// @stdout: 3|2.5|33|2.52.5|4|5
// @xfail(raiser): prints 0 for toString on an unnarrowed int32 | float64, card 2026-10-26-raiser-tostring-on-a-numeric-union-reads-zero
// note: a method every member of a tagged union shares (toString) is declared on no member's fields, so the payload read of `u.toString()` has no declaring member; a field the members declare (`u.x`) has one.

type Num = int32 | float64;

function text(u: Num): string { return u.toString(); }
function twice(this u: Num): string { return u.toString() + u.toString(); }

struct A { x: int32; }
struct B { x: int32; y: string; }
function field(u: A | B): int32 { return u.x; }

console.log(text(3) + "|" + text(2.5) + "|" + (3 as Num).twice() + "|" + (2.5 as Num).twice() + "|" + field({ x: 4 } as A) + "|" + field({ x: 5, y: "q" } as B));
