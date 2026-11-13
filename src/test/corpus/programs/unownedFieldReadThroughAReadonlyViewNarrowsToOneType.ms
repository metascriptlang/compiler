// @stdout: 2 2 0
// note: a local read from an Unowned field through a Readonly view, narrowed by a compound null test and merged back, keeps one type a Readonly<P> | null parameter takes.
class P { n: int32 = 1; next: Unowned<P> | null = null; }
function use(p: Readonly<P> | null): int32 { return p != null ? p.n : 0; }
function afterConditional(o: Readonly<P>): int32 {
	const e = o.next;
	const m = e != null && o.n > 0 ? 1 : 0;
	return use(e) + m;
}
function afterIf(o: Readonly<P>): int32 {
	const e = o.next;
	let m = 0;
	if (e != null && o.n > 0) m = 1;
	return use(e) + m;
}
const a = new P();
const b = new P();
a.next = b;
const c = new P();
console.log(afterConditional(a).toString() + " " + afterIf(a).toString() + " " + afterConditional(c).toString());
