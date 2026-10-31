// @stdout: 2 2
// @stdout: 20 1 -1
// @stdout: 6 1 -1
// @stdout: c -1
// @stdout: 4 2
// @stdout: -1 0
class Box {
	n: int32;
	tag: int32;
	constructor(n: int32, tag: int32) {
		this.n = n;
		this.tag = tag;
	}
}
struct P { x: int32; y: int32; }

function main(): void {
	const ns: number[] = [1, 2, 3, 2];
	const a = ns.findLast((x: number): boolean => x === 2);
	const b = ns.findLast((x: number, i: number): boolean => i < 3 && x === 2);
	const numbers = `${a != null ? a : -1} ${b != null ? 3 - ns.indexOf(b) : -1}`;

	const bs: Box[] = [new Box(1, 10), new Box(2, 20), new Box(1, 30)];
	const lastOne = bs.findLast((v: Box): boolean => v.n == 1);
	const lastTwo = bs.findLast((v: Box): boolean => v.n == 2);
	const lastNone = bs.findLast((v: Box): boolean => v.n == 9);
	const classes = `${lastOne != null ? lastOne.tag - 10 : -1} ${lastTwo != null ? lastTwo.tag / 20 : -1} ${lastNone != null ? lastNone.tag : -1}`;
	console.log(`${numbers}`);
	console.log(`${classes}`);

	const ps: P[] = [{ x: 1, y: 5 }, { x: 2, y: 6 }, { x: 1, y: 7 }];
	const sp = ps.findLast((p: P): boolean => p.x == 1);
	const sq = ps.findLast((p: P): boolean => p.x == 2);
	const sn = ps.findLast((p: P): boolean => p.x == 3);
	const structs = `${sp != null ? sp.y - 1 : -1} ${sq != null ? sq.y - 5 : -1} ${sn != null ? sn.y : -1}`;
	console.log(structs);

	const ws: string[] = ["a", "b", "c"];
	const wl = ws.findLast((w: string): boolean => w != "z");
	const wn = ws.findLast((w: string): boolean => w == "z");
	const strings = `${wl != null ? wl : "none"} ${wn != null ? wn : -1}`;
	console.log(strings);

	const is: int32[] = [4, 5, 4, 3];
	const il = is.findLast((x: int32): boolean => x < 5);
	const ic = is.findLast((x: int32): boolean => x == 5);
	console.log(`${il != null ? il + 1 : -1} ${ic != null ? is.indexOf(ic) + 1 : -1}`);

	const none: number[] = [];
	const nl = none.findLast((x: number): boolean => true);
	const one: number[] = [0];
	const ol = one.findLast((x: number): boolean => true);
	console.log(`${nl != null ? nl : -1} ${ol != null ? ol : -1}`);
}
main();
