// @stdout: classFn=after classNum=after iface=after shape=square:2 loop=4000

// A class or interface value placed in a union stays the same object: a mutation
// through the original reference is visible through the union, and a union read
// hands back that reference instead of a copy.
class Boxed {
	message: string;
	constructor(m: string) { this.message = m; }
}

interface Named {
	kind: "named";
	message: string;
}

interface Other {
	kind: "other";
	n: number;
}

interface Circle { kind: "circle"; r: float64; }
interface Square { kind: "square"; side: float64; }

type ClassFn = Boxed | ((p: Boxed) => Boxed);
type ClassNum = Boxed | number;
type Iface = Named | Other;
type Shape = Circle | Square;

function readClassFn(u: ClassFn): string {
	if (typeof u === "function") return "fn";
	return (u as Boxed).message;
}

function readClassNum(u: ClassNum): string {
	if (typeof u === "number") return "num";
	return (u as Boxed).message;
}

function readIface(u: Iface): string {
	if (u.kind === "named") return u.message;
	return "other";
}

function describe(s: Shape): string {
	if (s.kind === "circle") return "circle:" + s.r.toString();
	return "square:" + s.side.toString();
}

function unbox(u: ClassFn): Boxed {
	return u as Boxed;
}

export function main(): void {
	const b = new Boxed("before");
	const cf: ClassFn = b;
	const cn: ClassNum = b;
	b.message = "after";

	const nm: Named = { kind: "named", message: "before" };
	const iu: Iface = nm;
	nm.message = "after";

	const sq: Square = { kind: "square", side: 1 };
	const sh: Shape = sq;
	sq.side = 2;

	let i = 0;
	let acc = 0;
	while (i < 1000) {
		const t: ClassFn = new Boxed("loop");
		acc += unbox(t).message.length;
		i += 1;
	}
	console.log("classFn=" + readClassFn(cf) + " classNum=" + readClassNum(cn) + " iface=" + readIface(iu)
		+ " shape=" + describe(sh) + " loop=" + acc.toString());
}
main();
