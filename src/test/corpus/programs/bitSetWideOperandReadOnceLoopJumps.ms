// @stdout: for continue n 3 calls 4
// @stdout: do-while continue m 3 calls 7
// @stdout: for break n 1 calls 8

enum H { X0, X1, X2, X3, X4, X5, X6, X7, X8, X9, X10, X11, X12, X13, X14, X15, X16, X17, X18, X19, X20, X21, X22, X23, X24, X25, X26, X27, X28, X29, X30, X31, X32, X33, X34, X35, X36, X37, X38, X39, X40, X41, X42, X43, X44, X45, X46, X47, X48, X49, X50, X51, X52, X53, X54, X55, X56, X57, X58, X59, X60, X61, X62, X63, X64, X65, X66, X67, X68, X69, X70, X71, X72, X73, X74, X75, X76, X77, X78, X79, X80, X81, X82, X83, X84, X85, X86, X87, X88, X89, X90, X91, X92, X93, X94, X95, X96, X97, X98, X99 }

let calls = 0;
const b = (0 as BitSet<H>).incl(H.X70);

function mk(): BitSet<H> {
	calls += 1;
	return (0 as BitSet<H>).incl(H.X1).incl(H.X70);
}

function main(): void {
	let n = 0;
	for (let i = 0; i < 4; i += mk().intersection(b).size()) {
		if (i == 1) continue;
		n += 1;
	}
	console.log(`for continue n ${n} calls ${calls}`);
	let m = 0;
	do {
		m += 1;
		if (m == 2) continue;
	} while (mk().intersection(b).size() == 1 && m < 3);
	console.log(`do-while continue m ${m} calls ${calls}`);
	let j = 0;
	for (let i = 0; mk().intersection(b).size() == 1; i += 1) {
		j += 1;
		break;
	}
	console.log(`for break n ${j} calls ${calls}`);
}

main();
