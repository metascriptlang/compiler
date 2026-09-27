// @stdout: a-str 2.5 | a-str 2.5 | 7 b-str 4
// @xfail(raiser): the Raiser VM prints empty union payloads (' |  |  4' where C prints 'a-str 2.5 | a-str 2.5 | 7 b-str 4')
import { U as UA, mkA } from "./a";
import { U as UB, mkB } from "./b";

function id<T>(x: T): T {
	const y: T = x;
	return y;
}

function show(a: UA, b: UB): string {
	let out = "";
	if (typeof a === "string") out = out + a;
	if (typeof b === "number") out = out + " " + b.toString();
	return out;
}

const a: UA = mkA();
const b: UB = mkB();
const direct = show(a, b);
const viaId = show(id(a), id(b));
const as: UA[] = [mkA(), 7 as int32];
const bs: UB[] = [mkB(), "b-str"];
const a1 = as[1];
const b1 = bs[1];
let tail = "";
if (typeof a1 === "number") tail = tail + a1.toString();
if (typeof b1 === "string") tail = tail + " " + b1;
console.log(`${direct} | ${viaId} | ${tail} ${as.length + bs.length}`);
