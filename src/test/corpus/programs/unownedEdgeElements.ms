// @exit: 1
// @skip-js: C-only by design: onDestroy counts the frees the DRC makes and the check runs when the DRC frees the target; JS frees nothing
// @ledger-slack(H): 1
// @stdout: vec 3 / 1 2 3 / 9
// @stdout: pop 3, splice leaves 2 and 1
// @stdout: literal 2 then 1
// @stdout: struct copies 2 3 2
// @stdout: tree destroyed 1001
// @stdout: N destroyed 11
// @stdout: Error: 1 Unowned<N> edge(s) still point at the N being freed; each would dangle
// note: an Unowned<T> element of a field's own array (Vec<Unowned<T>> or Unowned<T>[]) is counted on push, index store, literal and struct copy and given up on pop, splice, reassignment and holder death, so a tree whose children keep their parents in an array stays acyclic and every target is freed exactly once; a target freed while an element still points at it stops the program.
class N { id: int32; constructor(id: int32) { this.id = id; } }
let destroyedN = 0;
function onDestroy(this n: N): void { destroyedN++; }

class H { ups: Vec<Unowned<N>> = []; }
class A { ups: Unowned<N>[] = []; }
struct S { ups: Vec<Unowned<N>>; }

class T {
	id: int32 = 0;
	kids: Vec<Owned<T>> = [];
	ups: Unowned<T>[] = [];
}
let destroyedT = 0;
function onDestroy(this t: T): void { destroyedT++; }

function vec(): void {
	const a = new N(1);
	const b = new N(2);
	const c = new N(3);
	const z = new N(9);
	const h = new H();
	h.ups.push(a);
	h.ups.push(b);
	h.ups.push(c);
	let line = "";
	for (const n of h.ups) line = line + n.id.toString() + " ";
	h.ups[0] = z;
	console.log("vec " + h.ups.length.toString() + " / " + line.trim() + " / " + h.ups[0].id.toString());
}

function popSplice(): void {
	const a = new N(1);
	const b = new N(2);
	const c = new N(3);
	const h = new A();
	h.ups.push(a);
	h.ups.push(b);
	h.ups.push(c);
	const last = h.ups.pop();
	h.ups.splice(0, 1);
	console.log("pop " + last.id.toString() + ", splice leaves " + h.ups[0].id.toString() + " and " + h.ups.length.toString());
}

function literal(): void {
	const a = new N(1);
	const b = new N(2);
	const h = new A();
	h.ups = [a, b];
	const first = h.ups.length;
	h.ups = [b];
	console.log("literal " + first.toString() + " then " + h.ups.length.toString());
}

function structCopies(): void {
	const a = new N(1);
	const b = new N(2);
	let s: S = { ups: [] };
	s.ups.push(a);
	s.ups.push(b);
	let t = s;
	t.ups.push(a);
	const before = t.ups.length;
	t = s;
	console.log("struct copies " + s.ups.length.toString() + " " + before.toString() + " " + t.ups.length.toString());
}

function tree(n: int32): void {
	const root: Owned<T> = new T();
	for (let i = 1; i <= n; i++) {
		const k: Owned<T> = new T();
		k.id = i;
		const r: T = root;
		k.ups.push(r);
		root.kids.push(move k);
	}
}

function dangle(h: H): void {
	const n = new N(7);
	h.ups.push(n);
}

vec();
popSplice();
literal();
structCopies();
tree(1000);
console.log("tree destroyed " + destroyedT.toString());
console.log("N destroyed " + destroyedN.toString());
const keeper = new H();
dangle(keeper);
console.log("unreachable " + keeper.ups.length.toString());
