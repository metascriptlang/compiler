// @xfail(raiser): raiser runs no user lifecycle hooks (stdout misses its @stdout line)
// @skip-js: C-only by design: user lifecycle hooks run where the DRC runs; JS has no destructors
// @stdout: nested=2 store=0 6

struct Item { id: int32; name: string; }
struct Holder { item: Item; n: int32; }
struct Outer { holder: Holder; spare: Item; }

let cloned: int32 = 0;

function onClone(this x: Item): Item {
	cloned += 1;
	return { id: x.id, name: x.name };
}

function nestedLiteral(): string {
	const a: Item = { id: 1, name: "a" + "x" };
	const outer: Outer = { holder: { item: a, n: 2 }, spare: a };
	const atInit = cloned;
	let later: Outer = { holder: { item: { id: 3, name: "c" + "z" }, n: 3 }, spare: { id: 4, name: "d" + "w" } };
	later.spare = a;
	return "nested=" + atInit.toString() + " store=" + (cloned - atInit).toString() + " "
		+ (outer.holder.item.id + outer.spare.id + outer.holder.n + later.spare.id + a.id).toString();
}

console.log(nestedLiteral());
