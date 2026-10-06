// @stdout: 7,4,6,40,2,1 -1,6,-4,-8,-1,-1.5 7,6,4,56,3,3.9000000000000004 -999998,0,-999997,-8000000,-500000,-0.25 400000002,0,400000003,-1094967296,200000000,0 global=1 box=3 arr=20,2.5,31 calls=3 f32=1.5 f64=0.5
// note: on a `number` target `x op= y` stores what `x = x op y` stores — the bitwise operators through int32, `%` through fmod — and reads x once, on C, JS and the Raiser; a float32 and a float64 `%=` take fmod too.

struct Box {
	v: number;
}

let calls: int32 = 0;
function next(): int32 {
	calls += 1;
	return calls - 1;
}

function row(s: number): string {
	let a = s;
	a |= 2;
	let b = s;
	b &= 6;
	let c = s;
	c ^= 3;
	let d = s;
	d <<= 3;
	let e = s;
	e >>= 1;
	let r = s;
	r %= 4;
	const same = a == (s | 2) && b == (s & 6) && c == (s ^ 3) && d == (s << 3) && e == (s >> 1) && r == s % 4;
	return `${a},${b},${c},${d},${e},${r}${same ? "" : "!"}`;
}

let g: number = 13.5;
g |= 16;
g %= 7;
let box: Box = { v: 9.5 };
box.v |= 4;
box.v %= 5;
const arr: number[] = [10.25, 20.5, 30.75];
arr[next()] <<= 1;
arr[next()] %= 3;
arr[next()] ^= 1;
let f: float32 = 7.5;
f %= 2;
let h: float64 = 6.5;
h %= 3;
const rows = [row(5), row(-1.5), row(7.9), row(-1000000.25), row(400000000)];
console.log(`${rows.join(" ")} global=${g} box=${box.v} arr=${arr.join(",")} calls=${calls} f32=${f} f64=${h}`);
