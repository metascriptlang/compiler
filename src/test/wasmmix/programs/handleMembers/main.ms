// @ledger-balanced: Counter
// @stdout: 12
// @stdout: 12
// @stdout: 6
// @stdout: 5
// @stdout: 7
// @stdout: > x=7 at 4,2
// @stdout: 4 2
// @stdout: 0,1,2
// @stdout: -3
// @stdout: 20 3
import { Handle } from "std/ffi";
import { open } from "./handleMembersWasm";

const h = open(5);
console.log(`${h.value().bump(7)}`);
console.log(`${h.value().n}`);
h.value().n = 3;
console.log(`${h.value().twice}`);
h.value().twice = 10;
console.log(`${h.value().n}`);
h.value().n += 1;
h.value().n++;
console.log(`${h.value().n}`);
h.value().label = "x";
h.value().at = { x: 4, y: 2 };
console.log(h.value().describe("> "));
console.log(`${h.value().at.x} ${h.value().at.y}`);
h.value().n = 3;
const seen: string[] = [];
h.value().each((v: int32): void => {
	seen.push(`${v}`);
});
console.log(seen.join(","));
console.log(`${h.value().release()}`);
const g = open(20);
console.log(`${g.value().n} ${h.value().n}`);
g.release();
h.release();
