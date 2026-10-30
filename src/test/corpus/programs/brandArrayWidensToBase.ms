// @stdout: 3 97 99 | 3 | 294 | 195 | 97 | 98,99 | 2 4 | 1 | 3 2 | 1 1
// note: a brand over an array (`uint8[] & { __brand: "Bytes" }`) is the array underneath: it indexes, has
// a length, iterates, spreads, slices, serves a `T[]`, `Readonly<Span<T>>` or generic `T[]` parameter, runs
// an extension declared on its base (the brand's own wins when both exist), and lives inside a Map value,
// an array and a class field.
type Bytes = uint8[] & { __brand: "Bytes" };
type Words = uint8[] & { __brand: "Words" };

function sumOf(s: Readonly<Span<uint8>>): int32 {
	let n = 0;
	for (const x of s) n += x;
	return n;
}
function lenOf(xs: uint8[]): int32 { return xs.length; }
function firstOf<T>(xs: T[]): T { return xs[0]; }
function readonlyFirst(xs: Readonly<uint8[]>): uint8 { return xs[0]; }
function width(this x: uint8[]): int32 { return 2; }
function width(this x: Words): int32 { return 4; }
function middle(b: Bytes): string {
	const m = b[1..3];
	return `${m[0]},${m[1]}`;
}
function second(this x: uint8[]): uint8 { return x[1]; }

class Holder {
	data: Bytes;
	constructor(data: Bytes) { this.data = data; }
}

const raw: uint8[] = [97, 98, 99];
const b = raw as Bytes;
let each = 0;
for (const x of b) each += x;
const copy: uint8[] = [...b];
const m = new Map<string, Bytes>();
m.set("k", b);
const list: Bytes[] = [b, raw as Bytes];
const h = new Holder(b);
const w = raw as Words;
const plain: uint8[] = b;
const view: Readonly<uint8[]> = b;
console.log(`${b.length} ${b[0]} ${b[2]} | ${lenOf(b)} | ${sumOf(b)} | ${each - 99} | ${firstOf(b)} | ${middle(b)} | ${b.width()} ${w.width()} | ${plain.length - 2} | ${m.get("k")!.length} ${list.length} | ${h.data.second() - 97} ${readonlyFirst(view) - 96}`);
