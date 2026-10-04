// @xfail(raiser): raiser runtime error: cannot evaluate 'super' at comptime (a derived constructor calling super)
// @stdout: 9 1 true false false true xy!z
// @exit: 0

import { Shape, Holder, makeSquare, holdName, isSquare } from "./shapes";
import { makeOther, holdMore, isOtherSquare } from "./other";

const a = makeSquare(3);
const b = makeOther("nw");
const h1 = holdName("x");
const h2 = holdMore("y");
const mine = new Holder<string>("z");
console.log(`${a.area()} ${b.area()} ${isSquare(a)} ${isSquare(b)} ${isOtherSquare(a)} ${isOtherSquare(b)} ${h1.item}${h2.item}${mine.item}`);
