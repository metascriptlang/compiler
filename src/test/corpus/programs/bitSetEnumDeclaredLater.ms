// @stdout: 4 8 true false true
// note: the set's type is written above its 20-member enum, so the checker meets
// BitSet<E> before E's members; the set must still be four bytes wide.

struct Holder { s: BitSet<E>; tag: int32; }

function make(): BitSet<E> {
	const local: BitSet<E> = E.M19 | E.M0;
	return local;
}

function main(): void {
	const h: Holder = { s: make(), tag: 7 };
	console.log(`${sizeof(BitSet<E>)} ${sizeof(Holder)} ${h.s.has(E.M19)} ${h.s.has(E.M5)} ${h.s.has(E.M0)}`);
}

enum E { M0, M1, M2, M3, M4, M5, M6, M7, M8, M9, M10, M11, M12, M13, M14, M15, M16, M17, M18, M19 }

main();
