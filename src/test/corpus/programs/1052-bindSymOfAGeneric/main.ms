// @stdout: 4 a! 4 7
// @exit: 0
// note: a macro binds a generic overload set through a literal bindSym; the call site neither imports it nor sees the caller's own `pick`. Each call instantiates the generic (int32, int64, an explicit type argument on the macro call) or picks the string overload. A literal bindSym of a generic used to be refused, and with no import at the call site msc crashed (exit 139).

import { first } from "./lib";

function pick(witness: int32, other: int32): string { return "hijacked"; }

const four: int32 = 4;
const seven: int64 = 7;
const a: string = "a";
console.log(first(four).toString() + " " + first(a) + " " + first<int32>(four).toString() + " " + first(seven).toString());
