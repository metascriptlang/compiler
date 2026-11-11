// @stdout: n7z9 n7z9 n7z9
// note: a class object passed as an interface or an unnamed record is the same object, so a field written through that view replaces what a read through the class borrowed: the read keeps its own copy of the old string.
interface Named { name: string; }
class N {
	name: string;
	constructor(name: string) { this.name = name; }
}
class Box { n: N; constructor(n: N) { this.n = n; } }
function mk(k: int32): N { return new N("n" + k.toString()); }
function rename(x: Named, k: int32): void { x.name = "z" + k.toString(); }
function renameRecord(x: { name: string }, k: int32): void { x.name = "z" + k.toString(); }
function direct(n: N): string {
	const s = n.name;
	rename(n, 9);
	return s + n.name;
}
function record(n: N): string {
	const s = n.name;
	renameRecord(n, 9);
	return s + n.name;
}
function throughBox(b: Box): string {
	const s = b.n.name;
	rename(b.n, 9);
	return s + b.n.name;
}
console.log(direct(mk(7)), record(mk(7)), throughBox(new Box(mk(7))));
