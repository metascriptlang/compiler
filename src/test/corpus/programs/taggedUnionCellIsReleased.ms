// Parity program — a union of repeated scalar kinds beside a string (`1 | 2 | string`) held in a
// local, a struct field, an array element and a named alias is released with its holder.
//
// @stdout: local 2|field 3|array 2|alias x2|swap qr
// @exit: 0

type Mixed = 1 | 2 | string;
struct Holder { u: 1 | 2 | string; n: int32; }

function local(): string {
	const u: 1 | 2 | string = 2;
	return "local " + (typeof u === "number" ? "2" : "s");
}

function field(): string {
	const h: Holder = { u: "x" + "y", n: 1 };
	const g: Holder = { u: 2, n: 2 };
	return "field " + (h.n + g.n);
}

function array(): string {
	const xs: (1 | 2 | string)[] = [];
	xs.push(2);
	xs.push("a" + "b");
	return "array " + xs.length;
}

function alias(): string {
	const m: Mixed = "x" + "";
	const k: Mixed = 2;
	return "alias " + (typeof m === "string" ? m : "n") + (typeof k === "number" ? "2" : "s");
}

function swap(): string {
	let u: 1 | 2 | string = 2;
	u = "q" + "r";
	return "swap " + (typeof u === "string" ? u : "n");
}

console.log([local(), field(), array(), alias(), swap()].join("|"));
