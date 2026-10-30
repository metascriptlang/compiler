// @stdout: class CI[2]
// @stdout: struct SI[3]
// @stdout: text CI<2> CI<2> CI<2> SI<3> SI<3>
// @stdout: only toString CT<7>
// @stdout: array CI[2],CI[4]
// @stdout: array SI[3],SI[5]
// @stdout: array CT<7>,CT<8>
// @stdout: { c: CI[2], s: SI[3], cs: [CI[2], CI[4]], n: 
// note: console.log reads a declared `inspect(): string` before `toString`, for the value itself, for each element of an array passed to it and for each field or element inside a printed struct or class; `String(x)`, a template, `+` and `.toString()` never read it, and a type that declares only `toString` prints as before. Same output on every lane.
class CI {
	n: int32;
	constructor(n: int32) { this.n = n; }
	inspect(): string { return "CI[" + this.n.toString() + "]"; }
	toString(): string { return "CI<" + this.n.toString() + ">"; }
}
struct SI { n: int32 }
function inspect(this s: SI): string { return "SI[" + s.n.toString() + "]"; }
function toString(this s: SI): string { return "SI<" + s.n.toString() + ">"; }
class CT {
	n: int32;
	constructor(n: int32) { this.n = n; }
	toString(): string { return "CT<" + this.n.toString() + ">"; }
}
struct Holder { c: CI; s: SI; cs: CI[]; n: int32 }

function main(): void {
	const ci = new CI(2);
	const si: SI = { n: 3 };
	console.log("class", ci);
	console.log("struct", si);
	console.log("text " + `${ci}` + " " + String(ci) + " " + ("" + ci) + " " + `${si}` + " " + ("" + si));
	console.log("only toString", new CT(7));
	console.log("array", [new CI(2), new CI(4)]);
	console.log("array", [{ n: 3 } as SI, { n: 5 } as SI]);
	console.log("array", [new CT(7), new CT(8)]);
	const h: Holder = { c: new CI(2), s: si, cs: [new CI(2), new CI(4)], n: 5 };
	console.log("holder", h);
}
main();
