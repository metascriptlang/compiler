// @skip-js: C-only by design: user lifecycle hooks run where the DRC runs; JS has no destructors
// note: Map<string, Owned<N>>, Set<Owned<N>> and a Map of structs holding Unowned<N> back edges keep N acyclic; dropping the root runs onDestroy once per node, a node shared by two maps included.
// @stdout: kids 3, parent of b is root
// @stdout: made 6 gone 6
// @stdout: set 2
// @stdout: made 9 gone 9
let made = 0;
let gone = 0;
struct Up { at: Unowned<N>; }
class N {
	name: string;
	kids: Map<string, Owned<N>> = new Map<string, Owned<N>>();
	tagged: Set<Owned<N>> = new Set<Owned<N>>();
	ups: Map<string, Up> = new Map<string, Up>();
	constructor(name: string) { this.name = name; made += 1; }
	onDestroy(): void { gone += 1; }
}
function adopt(parent: N, child: N): void {
	parent.kids.set(child.name, child);
	child.ups.set("parent", { at: parent });
}
function tree(): void {
	const root = new N("root");
	for (const name of ["a", "b", "c"]) adopt(root, new N(name));
	const b = root.kids.get("b")!;
	adopt(b, new N("b1"));
	adopt(root.kids.get("c")!, new N("c1"));
	root.kids.get("a")!.kids.set("shared", b.kids.get("b1")!);
	console.log("kids " + root.kids.size.toString() + ", parent of b is " + b.ups.get("parent")!.at.name);
}
function set(): void {
	const root = new N("root");
	root.tagged.add(new N("x"));
	root.tagged.add(new N("y"));
	console.log("set " + root.tagged.size.toString());
}
tree();
console.log("made " + made.toString() + " gone " + gone.toString());
set();
console.log("made " + made.toString() + " gone " + gone.toString());
