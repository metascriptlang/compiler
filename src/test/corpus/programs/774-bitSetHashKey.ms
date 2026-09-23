// @xfail(raiser): raiser runtime error: attempt to access a nil address
// @xfail(esm): tree emit: prelude container class binding never imported into the referencing module
// Parity program — a `BitSet<E>` as a hash-map key. C hashes it by value through
// the set's own hash; JS uses the native Map over the same word.
//
// @stdout: 2,first,second,true,false
// @exit: 0

enum E { A, B, C, D }

function main(): void {
	const s: BitSet<E> = E.A | E.C;
	const t: BitSet<E> = E.B | E.D;
	const same: BitSet<E> = E.C | E.A;
	const m: HashMap<BitSet<E>, string> = new HashMap();
	m.set(s, "first");
	m.set(t, "second");
	const bySame = m.get(same);
	const byT = m.get(t);
	console.log(`${m.size},${bySame != null ? bySame : "none"},${byT != null ? byT : "none"},${m.has(same)},${m.has((0 as BitSet<E>).incl(E.B))}`);
}
main();
