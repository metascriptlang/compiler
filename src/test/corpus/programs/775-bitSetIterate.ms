// @xfail(raiser): runs but stdout misses its @stdout line (exit=0)
// Parity program — a BitSet iterates its members in ordinal order and prints
// itself by member name, across both storage bands and for the empty set.
//
// @stdout: A,C|A,C|W3,W39||X5,X70,X99||{A, C}|{}|{X5, X70, X99}
// @exit: 0

enum E { A, B, C, D }
enum H { X0, X1, X2, X3, X4, X5, X6, X7, X8, X9, X10, X11, X12, X13, X14, X15, X16, X17, X18, X19, X20, X21, X22, X23, X24, X25, X26, X27, X28, X29, X30, X31, X32, X33, X34, X35, X36, X37, X38, X39, X40, X41, X42, X43, X44, X45, X46, X47, X48, X49, X50, X51, X52, X53, X54, X55, X56, X57, X58, X59, X60, X61, X62, X63, X64, X65, X66, X67, X68, X69, X70, X71, X72, X73, X74, X75, X76, X77, X78, X79, X80, X81, X82, X83, X84, X85, X86, X87, X88, X89, X90, X91, X92, X93, X94, X95, X96, X97, X98, X99 }
enum W { W0, W1, W2, W3, W4, W5, W6, W7, W8, W9, W10, W11, W12, W13, W14, W15, W16, W17, W18, W19, W20, W21, W22, W23, W24, W25, W26, W27, W28, W29, W30, W31, W32, W33, W34, W35, W36, W37, W38, W39 }

function names<T>(items: T[]): string {
	let out = "";
	for (const it of items) {
		if (out != "") { out = out + ","; }
		out = out + it.toString();
	}
	return out;
}

function main(): void {
	const s: BitSet<E> = E.A | E.C;
	const wide: BitSet<W> = W.W3 | W.W39;
	const empty: BitSet<E> = 0 as BitSet<E>;
	const huge: BitSet<H> = H.X5 | H.X70 | H.X99;
	const emptyH: BitSet<H> = huge.difference(huge);

	let viaForOf = "";
	for (const m of s) {
		if (viaForOf != "") { viaForOf = viaForOf + ","; }
		viaForOf = viaForOf + m.toString();
	}

	const parts: string[] = [
		viaForOf,
		names(s.toItems()),
		names(wide.toItems()),
		names(empty.toItems()),
		names(huge.toItems()),
		names(emptyH.toItems()),
		s.toString(),
		empty.toString(),
		huge.toString(),
	];
	console.log(parts.join("|"));
}
main();
