// @stdout: 2 2 true
// @exit: 0

enum W { W0, W1, W2, W3, W4, W5, W6, W7, W8, W9, W10, W11, W12, W13, W14, W15, W16, W17, W18, W19, W20, W21, W22, W23, W24, W25, W26, W27, W28, W29, W30, W31, W32, W33, W34, W35, W36, W37, W38, W39, W40, W41, W42, W43, W44, W45, W46, W47, W48, W49, W50, W51, W52, W53, W54, W55, W56, W57, W58, W59, W60, W61, W62, W63, W64, W65, W66, W67, W68, W69, W70, W71 }

function mk(): BitSet<W> {
	return (0 as BitSet<W>).incl(W.W1).incl(W.W70);
}

function main(): void {
	const t = mk();
	console.log(`${t.size()} ${mk().size()} ${t.has(W.W70)}`);
}
main();
