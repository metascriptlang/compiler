// @stdout: local=7
// @stdout: elem+=6
// @stdout: early=8
// @stdout: early null
// @stdout: int32=-7
// @stdout: field=7
// @stdout: uint32[]=7
// @stdout: number[]=7
// @stdout: class=9
// @stdout: map=1
// @stdout: member=9
// @stdout: nested=8
// @stdout: local+=5
// @stdout: field+=5
// @stdout: u8+=4
// @stdout: definite=3
// @stdout: definite=5
// @stdout: plain=7
// @stdout: read=1 len=3
//
// Differential program — after a null check, a nullable variable or field is
// narrowed when it is the RECEIVER of an assignment target (`v[0] = x`,
// `p.q.k = x`) and when it is the target of a compound assignment (`x += 1`).
// Only the node directly left of `=` / `&&=` / `||=` / `??=` reads its declared
// type. C and JS must print the same lines; each write is read back so a write
// that went to a copy shows up in stdout.
//
// `if (x === null) { x = <literal> }` is the control: a definite target still
// types its literal against the declared type.

struct Packet { values: Vec<uint32> | null; }
struct Q { k: int32; }
struct P { q: Q | null; }
struct Counter { n: int32 | null; }
class Box { values: number[] | null = [1, 2]; }

function pick(on: boolean): Vec<uint32> | null {
	if (on) { return [1, 2]; }
	return null;
}

function writeLocal(): void {
	let v: Vec<uint32> | null = [1, 2];
	if (v !== null) { v[0] = 7; console.log("local=" + v[0]); }
}

function compoundElement(): void {
	let v: Vec<uint32> | null = [1, 2];
	if (v !== null) { v[0] += 5; console.log("elem+=" + v[0]); }
}

function earlyReturn(on: boolean): void {
	let v = pick(on);
	if (v === null) { console.log("early null"); return; }
	v[1] = 8;
	console.log("early=" + v[1]);
}

function signedElement(): void {
	let v: Vec<int32> | null = [-1, 2];
	if (v !== null) { v[0] = -7; console.log("int32=" + v[0]); }
}

function writeField(ref packet: Packet): void {
	if (packet.values !== null) { packet.values[0] = 7; }
}

function uintArray(): void {
	let a: uint32[] | null = [1, 2];
	if (a !== null) { a[0] = 7; console.log("uint32[]=" + a[0]); }
}

function numberArray(): void {
	let a: number[] | null = [1, 2];
	if (a !== null) { a[0] = 7; console.log("number[]=" + a[0]); }
}

function classField(): void {
	const b = new Box();
	if (b.values !== null) { b.values[1] = 9; console.log("class=" + b.values[1]); }
}

function mapSubscript(): void {
	let m: Map<string, int32> | null = new Map<string, int32>();
	if (m !== null) { m["a"] = 1; console.log("map=" + m.get("a")); }
}

function structField(ref p: P): void {
	if (p.q !== null) { p.q.k = 9; }
}

function nestedElement(): void {
	let rows: Vec<Vec<uint32> | null> = [[1, 2]];
	let r = rows[0];
	if (r !== null) { r[1] = 8; console.log("nested=" + r[1]); }
}

function compoundLocal(x: int32 | null): void {
	if (x !== null) { x += 1; console.log("local+=" + x); }
}

function compoundField(ref c: Counter): void {
	if (c.n !== null) { c.n += 1; }
}

function compoundWraps(x: uint8 | null): void {
	if (x !== null) { x += 10; console.log("u8+=" + x); }
}

function definiteTarget(x: int32 | null): void {
	if (x === null) { x = 3; }
	console.log("definite=" + x);
}

function controls(): void {
	let plain: Vec<uint32> = [1, 2];
	plain[0] = 7;
	console.log("plain=" + plain[0]);
	let v: Vec<uint32> | null = [1, 2];
	if (v !== null) {
		const x = v[0];
		v.push(3);
		console.log("read=" + x + " len=" + v.length);
	}
}

function main(): void {
	writeLocal();
	compoundElement();
	earlyReturn(true);
	earlyReturn(false);
	signedElement();
	let packet: Packet = { values: [1, 2] };
	writeField(packet);
	if (packet.values !== null) { console.log("field=" + packet.values[0]); }
	uintArray();
	numberArray();
	classField();
	mapSubscript();
	let p: P = { q: { k: 1 } };
	structField(p);
	if (p.q !== null) { console.log("member=" + p.q.k); }
	nestedElement();
	compoundLocal(4);
	let c: Counter = { n: 4 };
	compoundField(c);
	console.log("field+=" + c.n);
	compoundWraps(250);
	definiteTarget(null);
	definiteTarget(5);
	controls();
}
main();
