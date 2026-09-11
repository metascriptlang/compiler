// Parity program — a `BitSet<E>` over an enum wider than one 32-bit word. The
// backing width follows the member count, so ordinal 39 lands in a 64-bit
// word on both backends.
//
// @stdout: true,true,false,false,true,true,false,true,549755813889,549755813888
// @exit: 0

enum Wide { W0, W1, W2, W3, W4, W5, W6, W7, W8, W9, W10, W11, W12, W13, W14, W15, W16, W17, W18, W19, W20, W21, W22, W23, W24, W25, W26, W27, W28, W29, W30, W31, W32, W33, W34, W35, W36, W37, W38, W39 }

function main(): void {
	const s: BitSet<Wide> = Wide.W0 | Wide.W39;
	const t = s.incl(Wide.W33).excl(Wide.W0);
	const none = t.excl(Wide.W33).excl(Wide.W39);
	console.log(`${s.has(Wide.W0)},${s.has(Wide.W39)},${s.has(Wide.W33)},${t.has(Wide.W0)},${t.has(Wide.W33)},${t.has(Wide.W39)},${t.isEmpty()},${none.isEmpty()},${s as uint64},${none.incl(Wide.W39) as uint64}`);
}
main();
