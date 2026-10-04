// @stdout: 5 9 5 3 3 3 10 8 40 13 true
// note: a const naming another aggregate const, one of its elements or one of its fields reads
//   the same values on every lane once folded to the constant it denotes; a class instance
//   bound to a second const stays the same object (guard solanaAggregateConstAlias).
import { BASE, KNOB, Knob } from "./lib/tables";
struct P { x: int32; y: int32; }
class Box { v: int32 = 1; }
const A: uint8[3] = [1, 5, 9];
const B: uint8[3] = A;
const B2: uint8[3] = B;
const C: uint8 = A[1];
const Q: P = { x: 2, y: 3 };
const R: P = Q;
const Y: int32 = Q.y;
const T: P[2] = [Q, { x: 4, y: 5 }];
const S2: int32 = A[0] + A[2];
const IMP: uint8[3] = BASE;
const IK: Knob = KNOB;
const box1 = new Box();
const box2 = box1;
function local(): int32 {
	const L: uint8[3] = A;
	return (L[2] as int32) + T[1].x;
}
console.log(`${B[1]} ${B2[2]} ${C} ${R.y} ${Y} ${T[0].y} ${S2} ${IMP[2]} ${IK.bump} ${local()} ${box1 === box2}`);
