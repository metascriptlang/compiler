// @stdout: 2 3 10 20 1 -1
// @exit: 0
// note: a macro's bindSym of a computed name binds in the macro's own module, so the module that expands it imports none of the names: a function, a const table and an enum from one library, and a same-named function from a second library bound by a second macro. The caller's own `other` stays its own.

import { callCube, callOther, weightAt, fastIndex } from "./macA";
import { callOtherB } from "./macB";

function other(x: int32): int32 { return -x; }

console.log(`${callCube(1)} ${callOther(1)} ${callOtherB(1)} ${weightAt(1)} ${fastIndex(0)} ${other(1)}`);
