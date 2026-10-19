// @stdout: 20 -1 1
// @exit: 0

type Small = { v: 1 | 2; t: uint8 };

function pick(k: int32): 1 | 2 | string { return k > 0 ? 2 : "s"; }
function scale(k: 1 | 2): int32 { return k * 10; }
function sign(positive: boolean): -1 | 1 { return positive ? 1 : -1; }

const x: 1 = 1;
console.log(x);

console.log(pick(1));
const w: 1 | 2 | string = 2;
console.log(w);

const s: Small = { v: 1, t: 1 };
console.log(s.v, s.t);

console.log(scale(2), sign(false), sign(true));

const half: 1.5 = 1.5;
const steps: 0.5 | 1.5 = 0.5;
console.log(half, steps);

const values: (1 | 2)[] = [1, 2, 2];
let total = 0;
for (const e of values) total += e;
console.log(total);

let v: 1 | 2 = 1;
v = 2;
switch (v) {
	case 1: console.log("one"); break;
	case 2: console.log("two"); break;
}
