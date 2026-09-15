// Parity program — a `BitSet<E>` in the slots that are typed by kind: an array
// element, a generic class argument, a nullable payload, on both width bands.
//
// @stdout: 3,true,true,true,true,true,false,true,false,true,true,true
// @exit: 0

enum E { A, B, C, D }
enum W { W0, W1, W2, W3, W4, W5, W6, W7, W8, W9, W10, W11, W12, W13, W14, W15, W16, W17, W18, W19, W20, W21, W22, W23, W24, W25, W26, W27, W28, W29, W30, W31, W32, W33, W34, W35, W36, W37, W38, W39 }

class Box<T> { v: T; constructor(v: T) { this.v = v; } get(): T { return this.v; } }

const some: BitSet<E> = E.A | E.C;

function pick(on: boolean): BitSet<E> | null { return on ? some : null; }

function main(): void {
	const arr: BitSet<E>[] = [some, 0 as BitSet<E>];
	arr.push(some.incl(E.D));
	const w: BitSet<W> = W.W1 | W.W39;
	const warr: BitSet<W>[] = [w, 0 as BitSet<W>];
	let acc = 0 as BitSet<W>;
	for (const x of warr) { acc = acc | x; }
	const b: Box<BitSet<E>> = new Box(some);
	const bw: Box<BitSet<W>> = new Box(w);
	const g = pick(true);
	const n = pick(false);
	console.log(`${arr.length},${arr[1].isEmpty()},${arr[2].has(E.D)},${arr[0] == some},${warr[0].has(W.W39)},${acc.has(W.W39)},${acc.has(W.W0)},${b.v.has(E.C)},${b.get().has(E.B)},${bw.get().has(W.W39)},${g != null ? g.has(E.C) : false},${n == null}`);
}
main();
