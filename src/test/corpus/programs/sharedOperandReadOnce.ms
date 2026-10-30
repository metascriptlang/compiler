// Parity program: a destructuring source, a word-class BitSet size and a nullable's text each read
// their operand once however many parts they take from it; `reads` counts evaluations of the call.
//
// @stdout: member:1,memberArr:1,index:1,rest:1,size:1,maybe:2
// @stdout: 1,2,3,4,12,13,1,2,2,5,null
// @exit: 0

enum Wide { W0, W1, W2, W3, W4, W5, W6, W7, W8, W9, W10, W11, W12, W13, W14, W15, W16, W17, W18, W19, W20, W21, W22, W23, W24, W25, W26, W27, W28, W29, W30, W31, W32, W33 }

interface P { x: int32; y: int32 }
interface Holder { pt: P; pair: int32[] }

let reads = 0;
function nextSet(): BitSet<Wide> { reads += 1; return Wide.W0 | Wide.W33; }
function nextHolder(): Holder { reads += 1; return { pt: { x: 1, y: 2 }, pair: [3, 4] }; }
function nextIndex(): int32 { reads += 1; return 1; }
function nextMaybe(): int32 | null { reads += 1; return 5; }
function nextNone(): int32 | null { reads += 1; return null; }

function main(): void {
	const table: int32[][] = [[10, 11], [12, 13]];
	const out: string[] = [];
	let mark = reads;
	const { x, y } = nextHolder().pt;
	out.push(`member:${reads - mark}`); mark = reads;
	const [a, b] = nextHolder().pair;
	out.push(`memberArr:${reads - mark}`); mark = reads;
	const [c, d] = table[nextIndex()];
	out.push(`index:${reads - mark}`); mark = reads;
	const { x: x2, ...rest } = nextHolder().pt;
	out.push(`rest:${reads - mark}`); mark = reads;
	const n = nextSet().size();
	out.push(`size:${reads - mark}`); mark = reads;
	const m = nextMaybe()?.toString() ?? "null";
	const none = nextNone()?.toString() ?? "null";
	out.push(`maybe:${reads - mark}`); mark = reads;
	console.log(out.join(","));
	console.log(`${x},${y},${a},${b},${c},${d},${x2},${rest.y},${n},${m},${none}`);
}
main();
