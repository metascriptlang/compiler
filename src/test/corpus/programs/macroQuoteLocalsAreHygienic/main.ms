// @stdout: 3 4 6 6005 10 11
// @exit: 0
// note: a name a `quote` declares — a const, a for-of binding, an arrow parameter — is fresh at every expansion, so the caller's `x` handed in through `${}` stays the caller's, at run time, in a generic and through the compile-time copy of a generic. These used to resolve to the quote's own `x`: 99 on JS everywhere and on C through @comptime.

import { Node } from "std/meta";

macro shadowX(arg: Node): Node { return quote { ((): int32 => { const x = 99; return ${arg}; })() }; }
macro shadowLoop(arg: Node): Node { return quote { ((): int32 => { let s = 0; for (const x of [99]) s = s + ${arg}; return s; })() }; }
macro shadowParam(arg: Node): Node { return quote { ((x: int32): int32 => ${arg})(99) }; }

function plain(x: int32): int32 { return shadowX(x); }
function lab<T>(t: T, x: int32): int32 { return shadowX(x); }
function labLocal<T>(t: T): int32 { const x = 6; return shadowX(x); }
function loop(x: int32): int32 { return shadowLoop(x); }
function param(x: int32): int32 { return shadowParam(x); }

const folded = @comptime { return lab(1, 5) + labLocal(1) * 1000; };
console.log(`${plain(3)} ${lab(1, 4)} ${labLocal(1)} ${folded} ${loop(10)} ${param(11)}`);
