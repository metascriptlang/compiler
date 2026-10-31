// @stdout: 2,3,4
// @stdout: 4,5
// @stdout: 1,2,3,4,5
// @stdout:
// @stdout: 5
// @stdout: 1,2
// @stdout: 1,2,3,4,5 5
function make(values: number[]): Buffer {
	when (js) { return Buffer.fromArray(values); } else {
		const raw: uint8[] = [];
		for (const v of values) raw.push(v as uint8);
		return raw as Buffer;
	}
}
function show(b: Buffer): string {
	let out = "";
	for (let i = 0; i < b.length; i++) out += (i > 0 ? "," : "") + b[i].toString();
	return out;
}
const b = make([1, 2, 3, 4, 5]);
console.log(show(b.slice(1, 4)));
console.log(show(b.slice(-2)));
console.log(show(b.slice()));
console.log(show(b.slice(3, 1)));
console.log(show(b.slice(-1)));
console.log(show(b.slice(0, -3)));
const whole = b.slice(0, 100);
console.log(show(whole) + " " + whole.length.toString());
