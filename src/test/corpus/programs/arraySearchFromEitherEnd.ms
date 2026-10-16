// @stdout: 0 2 2 1 | 0 0 2 -1 -1 0 | 1 -1 1 | 2 0 -1 1 2 | 1 3 -1 -1 3 | 2 0 -1 1 -1 | -1 0 -1 -1 -1 | 2
class Box {
	n: int32;
	constructor(n: int32) {
		this.n = n;
	}
}
struct P { x: int32; y: int32; }

function main(): void {
	const a = new Box(1);
	const b = new Box(2);
	const xs: Box[] = [a, b, a];
	const ns: number[] = [1, 2, 1];
	const fi: number[] = [3, 4, 5];
	const card = `${xs.indexOf(a)} ${xs.lastIndexOf(a)} ${ns.lastIndexOf(1)} ${fi.findIndex((x: number): boolean => x === 4)}`;

	const from = `${ns.lastIndexOf(1, 1)} ${ns.lastIndexOf(1, -2)} ${ns.lastIndexOf(1, 10)} ${ns.lastIndexOf(1, -4)} ${ns.lastIndexOf(2, 0)} ${ns.lastIndexOf(1, 0)}`;

	const other = new Box(1);
	const identity = `${xs.lastIndexOf(b)} ${xs.lastIndexOf(other)} ${xs.findIndex((x: Box): boolean => x.n == 2)}`;

	const ps: P[] = [{ x: 1, y: 2 }, { x: 3, y: 4 }, { x: 1, y: 2 }];
	const q: P = { x: 1, y: 2 };
	const r: P = { x: 9, y: 9 };
	const structs = `${ps.lastIndexOf(q)} ${ps.lastIndexOf(q, 1)} ${ps.lastIndexOf(r)} ${ps.findIndex((p: P): boolean => p.y == 4)} ${ps.findLastIndex((p: P): boolean => p.x == 1)}`;

	const fl: number[] = [3, 4, 5, 4];
	const finds = `${fl.findIndex((x: number): boolean => x === 4)} ${fl.findLastIndex((x: number): boolean => x === 4)} ${fl.findIndex((x: number): boolean => x > 9)} ${fl.findLastIndex((x: number): boolean => x > 9)} ${fl.findIndex((x: number, i: number): boolean => i > 1 && x === 4)}`;

	const ws: string[] = ["a", "b", "a"];
	const needle = "ba".slice(1, 2);
	const noWords: string[] = [];
	const strings = `${ws.lastIndexOf(needle)} ${ws.lastIndexOf(needle, 1)} ${ws.lastIndexOf(needle, -4)} ${ws.findLastIndex((w: string): boolean => w == "b")} ${noWords.lastIndexOf(needle)}`;

	const nan: number[] = [NaN];
	const zero: number[] = [0];
	const none: number[] = [];
	const edges = `${nan.lastIndexOf(NaN)} ${zero.lastIndexOf(-0)} ${none.lastIndexOf(1)} ${none.findIndex((x: number): boolean => x === 1)} ${none.findLastIndex((x: number): boolean => x === 1)}`;

	const is: int32[] = [5, 6, 5];
	console.log(`${card} | ${from} | ${identity} | ${structs} | ${finds} | ${strings} | ${edges} | ${is.lastIndexOf(5)}`);
}
main();
