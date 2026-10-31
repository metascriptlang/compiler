// A string stored from one field or element into another is its own copy: growing, trimming or
// overwriting either side leaves the other unchanged, for ASCII and non-ASCII text, with a slot
// that has room to reuse, a slot that is too small, a literal, and a source that is its own slot.

class Pair { a: string = ""; b: string = ""; }

function id(s: string): string { return s; }

function grow(first: int32, count: int32): string {
	let s = "";
	for (let j: int32 = 0; j < count; j++) s += String.fromCharCode(first + (j % 26));
	return s;
}

function report(tag: string, s: string): void {
	console.log(tag + " [" + s + "] len=" + s.length + " c1=" + s.charCodeAt(1));
}

function main(): void {
	const src = [grow(97, 6), grow(0x430, 3), "lit"];
	const dst = [grow(97, 30), grow(97, 2), grow(0x430, 9)];

	for (let i: int32 = 0; i < 3; i++) {
		dst[i] = src[i];
		report(`elem${i}`, dst[i]);
	}
	dst[0] = dst[0] + "Z";
	dst[1] = dst[1] + id("é");
	dst[2] = dst[2].trim() + "!";
	for (let i: int32 = 0; i < 3; i++) {
		report(`dst${i}`, dst[i]);
		report(`src${i}`, src[i]);
	}

	dst[0] = dst[1];
	dst[1] = dst[2];
	dst[2] = dst[2];
	for (let i: int32 = 0; i < 3; i++) report(`chain${i}`, dst[i]);

	const p = new Pair();
	p.a = grow(0x430, 12);
	p.b = grow(97, 40);
	p.b = p.a;
	report("field1", p.b);
	p.a = "ascii";
	report("field2", p.b);
	report("field3", p.a);
	p.a = p.b;
	p.b = p.b + "-more";
	report("field4", p.a);
	report("field5", p.b);

	const q = new Pair();
	q.a = src[0];
	q.b = dst[0];
	q.b = q.a;
	report("mixed", q.b);
	q.a = src[1];
	report("mixed2", q.b);
}

main();
