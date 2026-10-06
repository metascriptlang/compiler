// @stdout: root=4 mid=3 leaf=2 local=1 as=3 dispatch=gau
// @xfail(raiser): the Raiser VM has no `instanceof` ('cannot evaluate operator 'instanceof' at comptime')
// note: the base classes live in another module — the child's display entry names a base
// TypeInfo defined there, filled at the child's DatInit (topological order: the base module
// initialises first). One msTypeInfo per class across modules (CG-17) makes the address
// display exact. Sibling of 822; same-module matrix is 873.

import { Root, Mid, Leaf, mkLeaf } from "./instanceDisplayLib";

class Local extends Leaf {}

function main(): void {
	const xs: unknown[] = [new Root(), new Mid(), mkLeaf(), new Local()];
	let root = 0;
	let mid = 0;
	let leaf = 0;
	let local = 0;
	for (const x of xs) {
		if (x instanceof Root) root += 1;
		if (x instanceof Mid) mid += 1;
		if (x instanceof Leaf) leaf += 1;
		if (x instanceof Local) local += 1;
	}
	const u: unknown = mkLeaf();
	const parts: string[] = [
		`root=${root}`, `mid=${mid}`, `leaf=${leaf}`, `local=${local}`,
		`as=${(u as Leaf).l}`,
	];
	const r: Root = mkLeaf();
	parts.push(`dispatch=${r.speak()}`);
	console.log(parts.join(" "));
}
main();
