// Two headers that include a third name its types as one: a struct and an enum the third header
// declares, made in a module that imports the first header, pass to functions of a module that
// imports the second, and nest in a struct of each header.
// @stdout: 5 1|7 9|5
// @exit: 0

import { Pair, Mode, User } from "./user.h";
import { Maker } from "./maker.h";
import { makePair, onMode } from "./make";

function sum(p: Pair): int32 { return p.a + p.b; }
function code(m: Mode): int32 { return m as int32; }

const u: User = { last: makePair(7, 9) };
const m: Maker = { first: makePair(2, 3), mode: onMode() };
console.log(`${sum(makePair(2, 3))} ${code(onMode())}|${u.last.a} ${u.last.b}|${sum(m.first)}`);
