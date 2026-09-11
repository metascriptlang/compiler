// Parity program — a `BitSet<E>` over an enum wider than 64 members. The backing
// store is a fixed word array on both backends, so membership indexes a word
// and set-valued operations rebuild the array element-wise.
//
// @stdout: true,true,true,false,false,true,true,true,false,true,true,false,true,false,true,true,false,3
// @exit: 0

enum Wide { W0, W1, W2, W3, W4, W5, W6, W7, W8, W9, W10, W11, W12, W13, W14, W15, W16, W17, W18, W19, W20, W21, W22, W23, W24, W25, W26, W27, W28, W29, W30, W31, W32, W33, W34, W35, W36, W37, W38, W39, W40, W41, W42, W43, W44, W45, W46, W47, W48, W49, W50, W51, W52, W53, W54, W55, W56, W57, W58, W59, W60, W61, W62, W63, W64, W65, W66, W67, W68, W69, W70, W71, W72, W73, W74, W75, W76, W77, W78, W79, W80, W81, W82, W83, W84, W85, W86, W87, W88, W89, W90, W91, W92, W93, W94, W95, W96, W97, W98, W99 }

function mk(): BitSet<Wide> { return Wide.W1 | Wide.W40; }

function main(): void {
	const s: BitSet<Wide> = Wide.W0 | Wide.W40 | Wide.W99;
	const t = s.incl(Wide.W33).excl(Wide.W0);
	const none = 0 as BitSet<Wide>;
	const u = s | t;
	const v = s & t;
	let k = 0;
	let acc = none;
	while (!acc.has(Wide.W99)) {
		acc = acc.incl(k == 2 ? Wide.W99 : Wide.W5);
		k += 1;
	}
	console.log(`${s.has(Wide.W0)},${s.has(Wide.W40)},${s.has(Wide.W99)},${s.has(Wide.W33)},${t.has(Wide.W0)},${t.has(Wide.W33)},${t.has(Wide.W99)},${none.isEmpty()},${t.isEmpty()},${u.has(Wide.W0)},${u.has(Wide.W33)},${v.has(Wide.W0)},${v.has(Wide.W40)},${s == t},${s == t.incl(Wide.W0).excl(Wide.W33)},${mk().has(Wide.W40)},${mk().has(Wide.W0)},${k}`);
}
main();
