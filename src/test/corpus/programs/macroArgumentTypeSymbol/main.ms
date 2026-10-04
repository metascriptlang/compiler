// @stdout: 1 2 1 3 1
// @exit: 0
// note: a type name inside a macro argument reaches the macro as that type's symbol, so `getImpl` reads its declaration — for a type of the calling module, an enum, an imported struct and class, and a type nested in an array argument. The argument used to arrive as a bare name and `getImpl` stopped the build with "node is not a symbol".

import { declKind, firstDeclKind } from "./describe";
import { Remote, Owner } from "./shapes";

struct Local { seed: uint64; }
enum Mode { On, Off }

const a: int32 = declKind(Local);
const b: int32 = declKind(Mode);
const c: int32 = declKind(Remote);
const d: int32 = declKind(Owner);
const e: int32 = firstDeclKind([Local]);
console.log(String(a), String(b), String(c), String(d), String(e));
