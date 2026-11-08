// @skip-js: C-only by design: onDestroy counts the frees the DRC makes; JS frees nothing
// @stdout: flat 1 destroyed 2
// @stdout: tree sum 5 destroyed 13
// note: a cyclic class whose Vec field holds its own type releases each element exactly once when the holder dies, so a Raiser element release clears the slot before the array's own release walks it.
let destroyed = 0;
class N {
	id: int32 = 0;
	kids: Vec<N> = [];
	constructor(id: int32) { this.id = id; }
	onDestroy() { destroyed += 1; }
}
function flat(): int32 {
	const root = new N(0);
	root.kids.push(new N(1));
	return root.kids.length;
}
function build(depth: int32): N {
	const n = new N(depth);
	if (depth > 0) {
		for (let i = 0; i < 3; i += 1) n.kids.push(build(depth - 1));
	}
	return n;
}
function sum(n: N): int32 {
	let total = n.id;
	for (let i = 0; i < n.kids.length; i += 1) total += sum(n.kids[i]);
	return total;
}
function tree(): int32 {
	const root = build(2);
	return sum(root);
}
const f = flat();
console.log(`flat ${f} destroyed ${destroyed}`);
destroyed = 0;
const t = tree();
console.log(`tree sum ${t} destroyed ${destroyed}`);
