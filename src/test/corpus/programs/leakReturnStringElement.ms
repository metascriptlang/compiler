// @maxrss: 30
// @stdout: leak-return-string-element 200000 200000 200000 200000
class Inner { items: string[] = []; }
class Outer { b: Inner = new Inner(); }
function get(a: string[], i: number): string { return a[i]; }
function nested(o: Outer, i: number): string { return o.b.items[i]; }
function guarded(a: string[], i: number, mode: number): string {
	if (mode == 0) return a[i];
	if (mode == 1) return a[i + 1];
	return a[i];
}
function guardedField(o: Outer, i: number, mode: number): string {
	if (mode == 0) return o.b.items[i];
	if (mode == 1) return o.b.items[i + 1];
	return o.b.items[i];
}

const pad = "x".repeat(200);
const texts: string[] = ["", ""];
const o = new Outer();
o.b.items.push("");
o.b.items.push("");
let viaGet = 0;
let viaNested = 0;
let viaGuarded = 0;
let viaGuardedField = 0;
for (let k = 0; k < 200000; k++) {
	const s = `${k} ${pad}`;
	texts[0] = s;
	texts[1] = s + "y";
	o.b.items[0] = s;
	o.b.items[1] = s + "z";
	viaGet += get(texts, 0).length > 0 ? 1 : 0;
	viaNested += nested(o, 0).length > 0 ? 1 : 0;
	viaGuarded += guarded(texts, 0, k % 3).length > 0 ? 1 : 0;
	viaGuardedField += guardedField(o, 0, k % 3).length > 0 ? 1 : 0;
}
console.log("leak-return-string-element", viaGet, viaNested, viaGuarded, viaGuardedField);
