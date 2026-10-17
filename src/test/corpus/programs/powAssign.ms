// @stdout: 81 1099511627776 6.25 3 1,8,3 2 25 3.375 2,9 1 NaN 243 2.25
// note: `x **= y` parses and stores what `x = x ** y` stores, on an int32, int64, uint8,
// number, float32, an array element, an element with an effectful index (evaluated once),
// and integer and float fields, with ECMAScript's NaN for a NaN exponent.

class P {
	n: int32 = 5;
	x: number = 1.5;
}

let k: int32 = 0;
function next(): int32 {
	k += 1;
	return 1;
}

let i: int32 = 3;
i **= 4;
let big: int64 = 2;
big **= 40;
let f = 2.5;
f **= 2;
let g: number = 9;
g **= 0.5;
const a: int32[] = [1, 2, 3];
a[1] **= 3;
const fa: number[] = [0.5, 4];
fa[1] **= 0.5;
const p = new P();
p.n **= 2;
p.x **= 3;
const b: number[] = [2, 3];
b[next()] **= 2;
let n2: number = 1;
n2 **= NaN;
let u8: uint8 = 3;
u8 **= 5;
let f32: float32 = 1.5;
f32 **= 2;
console.log(`${i} ${big} ${f} ${g} ${a.join(",")} ${fa[1]} ${p.n} ${p.x} ${b.join(",")} ${k} ${n2} ${u8} ${f32}`);
