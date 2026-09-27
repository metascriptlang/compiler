// @stdout: 10 8 r 19
// note: an object type with no name that reaches itself through an array (directly, through a second type, or one nesting level deeper) gets a C name (main-reg-2, codegen half: the structural key recursed until the compiler overflowed its stack).

type Tree = { kids: Tree[]; v: int32 };
type Left = { rights: Right[]; x: int32 };
type Right = { lefts: Left[]; name: string };
type Outer = { inner: { back: Outer[]; w: int32 }; v: int32 };

function sum(t: Tree): int32 {
	let s = t.v;
	for (const k of t.kids) s += sum(k);
	return s;
}

function run(): void {
	const leaf: Tree = { kids: [], v: 2 };
	const mid: Tree = { kids: [leaf, { kids: [], v: 3 }], v: 4 };
	const root: Tree = { kids: [mid], v: 1 };
	const r: Right = { lefts: [], name: "r" };
	const l: Left = { rights: [r], x: 7 };
	const o: Outer = { inner: { back: [], w: 5 }, v: 6 };
	o.inner.back.push({ inner: { back: [], w: 8 }, v: 9 });
	console.log(sum(root), l.x + l.rights.length, l.rights[0].name, o.v + o.inner.w + o.inner.back[0].inner.w);
}
run();
