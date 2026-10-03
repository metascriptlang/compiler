// @skip-js: C-only by design: user lifecycle hooks run where the DRC runs; JS has no destructors
// @stdout: clones literal=2 field=1 let=0 assign=0 return=0

struct Item { id: int32; name: string; }
struct Holder { item: Item; n: int32; }

let cloned: int32 = 0;

function onClone(this x: Item): Item {
	cloned += 1;
	return { id: x.id, name: x.name };
}

function same(x: Item): Item { return x; }

function take(): int32 {
	const n = cloned;
	cloned = 0;
	return n;
}

function shapes(): string {
	const a: Item = { id: 1, name: "a" + "x" };
	const list: Item[] = [a, a];
	const literal = take();
	const holder: Holder = { item: a, n: 1 };
	const field = take();
	const copy = a;
	const letCopy = take();
	let target: Item = { id: 2, name: "b" + "y" };
	target = a;
	const assign = take();
	const back = same(a);
	const ret = take();
	return "clones literal=" + literal.toString() + " field=" + field.toString() + " let=" + letCopy.toString()
		+ " assign=" + assign.toString() + " return=" + ret.toString()
		+ " " + (list.length + holder.n + copy.id + target.id + back.id).toString();
}

console.log(shapes());
