// @stdout: init=init arg=arg ret=ret str=s

// A `new` with arguments keeps its own class type when it meets a union that also
// holds `null` and a function: the union's nullable carrier is only the fit
// target, never the constructed type.
class Boxed {
	message: string;
	constructor(m: string) { this.message = m; }
}

type SetLike = Boxed | null | ((prev: Boxed | null) => Boxed | null);
type StrLike = Boxed | string | null;

function take(v: SetLike): string {
	if (v == null) return "null";
	if (typeof v === "function") return "fn";
	return (v as Boxed).message;
}

function give(): StrLike {
	return new Boxed("ret");
}

function giveStr(): StrLike {
	return "s";
}

export function main(): void {
	const x: SetLike = new Boxed("init");
	const r = give();
	let ret = "none";
	if (r != null && typeof r !== "string") ret = (r as Boxed).message;
	const s = giveStr();
	let str = "none";
	if (s != null && typeof s === "string") str = s;
	console.log("init=" + take(x) + " arg=" + take(new Boxed("arg")) + " ret=" + ret + " str=" + str);
}
main();
