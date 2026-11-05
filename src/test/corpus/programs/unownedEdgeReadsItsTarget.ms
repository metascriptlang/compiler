// note: an Unowned<T> field reads as its target on every backend: 1000 up-edges of an owned tree, the same edge copied through struct values, an array of them and a struct literal in that array, and a module global target declared before its holder.
class T {
	id: int32 = 0;
	kids: Vec<Owned<T>> = [];
	up: Unowned<T> | null = null;
}

class N { id: int32 = 4; }
struct View { at: Unowned<N> | null; tag: int32; }
class H { at: Unowned<N> | null = null; }

function tree(n: int32): void {
	const root: Owned<T> = new T();
	for (let i = 1; i <= n; i++) {
		const k: Owned<T> = new T();
		k.id = i;
		const r: T = root;
		k.up = r;
		root.kids.push(move k);
	}
	let sum = 0;
	for (const k of root.kids) {
		const p = k.up;
		if (p != null) sum += p.id + k.id;
	}
	console.log("tree sum " + sum.toString());
}

function views(): void {
	const n: N = new N();
	let a: View = { at: null, tag: 1 };
	a.at = n;
	const b: View = a;
	const xs: View[] = [a, b, { at: n, tag: 3 }, a];
	let sum = 0;
	for (const v of xs) {
		const t = v.at;
		if (t != null) sum += t.id + v.tag;
	}
	console.log("views sum " + sum.toString() + " id " + n.id.toString());
}

const keep: N = new N();
keep.id = 9;
const h: H = new H();
h.at = keep;

tree(1000);
views();
const seen = h.at;
if (seen != null) console.log("global seen " + seen.id.toString());
