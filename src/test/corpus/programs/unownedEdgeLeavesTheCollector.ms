// @skip-js: C-only by design: onDestroy counts the frees the DRC makes; JS has no destructors
// @stdout: tree destroyed 1001
// @stdout: holder in a garbage cycle: N destroyed 1
// @stdout: ring destroyed 5000
// @stdout: views: N destroyed 1
// note: an Unowned<T> edge is not an owning edge, so a tree with up-edges stays acyclic and frees every node when its root drops; a holder inside a garbage cycle and a cyclic target freed by the collector both release their edges before the target's check, so neither stops the program; edges stored through struct copies and a struct literal leave their target freed exactly once.
import { collectCycles } from "std/runtime";

class T {
	id: int32 = 0;
	kids: Vec<Owned<T>> = [];
	up: Unowned<T> | null = null;
}
let destroyedT = 0;
function onDestroy(this t: T): void { destroyedT++; }

class N { id: int32 = 3; }
let destroyedN = 0;
function onDestroy(this n: N): void { destroyedN++; }

class S {
	self: S | null = null;
	decl: Unowned<N> | null = null;
}

class C {
	id: int32 = 0;
	next: C | null = null;
	back: Unowned<C> | null = null;
}
let destroyedC = 0;
function onDestroy(this c: C): void { destroyedC++; }

struct View { at: Unowned<N> | null; tag: int32; }

function tree(n: int32): void {
	const root: Owned<T> = new T();
	for (let i = 1; i <= n; i++) {
		const k: Owned<T> = new T();
		k.id = i;
		const r: T = root;
		k.up = r;
		root.kids.push(move k);
	}
}

function cyclicHolder(): void {
	const n: N = new N();
	const s: S = new S();
	s.self = s;
	s.decl = n;
}

function ring(n: int32): void {
	const first: C = new C();
	let prev: C = first;
	for (let i = 1; i < n; i++) {
		const c: C = new C();
		c.id = i;
		c.back = prev;
		prev.next = c;
		prev = c;
	}
	prev.next = first;
	first.back = prev;
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
		if (t != null) sum += t.id;
	}
	console.log("views sum " + sum.toString());
}

tree(1000);
console.log("tree destroyed " + destroyedT.toString());
cyclicHolder();
collectCycles();
console.log("holder in a garbage cycle: N destroyed " + destroyedN.toString());
for (let r = 0; r < 100; r++) ring(50);
collectCycles();
console.log("ring destroyed " + destroyedC.toString());
destroyedN = 0;
views();
console.log("views: N destroyed " + destroyedN.toString());
