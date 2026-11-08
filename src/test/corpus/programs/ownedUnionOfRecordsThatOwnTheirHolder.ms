// @skip-js: C-only by design: onDestroy counts the DRC's destroys; JS frees nothing
// @stdout: kinds pair many leaf
// @stdout: made 6 gone 6
// note: Owned<D> over a union of records that themselves own the class holding D resolves once every record is shaped, so the class declares its data as plain record literals and every node is destroyed once.
let made = 0;
let gone = 0;
type Leaf = { name: string };
type Pair = { left: Owned<N>, right: Owned<N> };
type Many = { items: Owned<N>[] };
type D = Leaf | Pair | Many;
class N {
	v: int32 = 0;
	data: Owned<D> = { name: "" };
	constructor() { made += 1; }
	onDestroy(): void { gone += 1; }
}

function kind(d: D): string {
	if ("left" in d) return "pair";
	if ("items" in d) return "many";
	return "leaf";
}

function main(): void {
	{
		const r = new N();
		const a = new N();
		a.data = { items: [new N(), new N()] };
		r.data = { left: a, right: new N() };
		const pair = r.data;
		const leaf = new N();
		console.log("kinds " + kind(pair) + " " + kind(a.data) + " " + kind(leaf.data));
	}
	console.log("made " + made.toString() + " gone " + gone.toString());
}
main();
