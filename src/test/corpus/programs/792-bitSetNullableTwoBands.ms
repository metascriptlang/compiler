// Parity program — two `BitSet<E>` over different enums, each in its own
// nullable slot. The Maybe cache must key a set by its element, not by the
// shared "BitSet" spelling, or whichever slot is checked first claims the
// other one's payload.
//
// @stdout: true,true,true,true
// @exit: 0

enum E { A, B, C, D }
enum W { W0, W1, W2, W3, W4, W5, W6, W7, W8, W9, W10, W11, W12, W13, W14, W15, W16, W17, W18, W19, W20, W21, W22, W23, W24, W25, W26, W27, W28, W29, W30, W31, W32, W33, W34, W35, W36, W37, W38, W39 }

function pickE(on: boolean): BitSet<E> | null { return on ? (E.A | E.C) : null; }
function pickW(on: boolean): BitSet<W> | null { return on ? (W.W1 | W.W39) : null; }

function main(): void {
	const e = pickE(true);
	const w = pickW(true);
	const ne = pickE(false);
	const nw = pickW(false);
	console.log(`${e != null ? e.has(E.C) : false},${w != null ? w.has(W.W39) : false},${ne == null},${nw == null}`);
}
main();
