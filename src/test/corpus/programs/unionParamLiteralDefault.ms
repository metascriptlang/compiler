// @stdout: top,0,3
// @stdout: loop,0,3
// @stdout: given,3,3
// @stdout: bytes,0,2
// @stdout: method,0,1
// @stdout: ctor,0,5
// @stdout: num,7,2.5
type Data = string | uint8[];

function size(d: Data): number {
	if (typeof d == "string") return d.length;
	return d.length;
}

function tagged(label: string, aad: Data = "", body: Data = "abc"): string {
	return label + "," + size(aad).toString() + "," + size(body).toString();
}

class Seal {
	run(aad: Data = ""): string { return "method," + size(aad).toString() + ",1"; }
}

class Box {
	text: string;
	constructor(aad: Data = "", body: Data = "hello") { this.text = "ctor," + size(aad).toString() + "," + size(body).toString(); }
}

function pick(a: number | string = 7, b: number | string = 2.5): string {
	return "num," + a.toString() + "," + b.toString();
}

console.log(tagged("top"));
for (let i = 0; i < 2; i++) {
	if (i == 1) console.log(tagged("loop"));
}
console.log(tagged("given", "xyz"));
const raw: uint8[] = [1, 2];
console.log(tagged("bytes", "", raw));
console.log(new Seal().run());
console.log(new Box().text);
console.log(pick());
