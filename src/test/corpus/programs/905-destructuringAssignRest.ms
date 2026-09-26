// @stdout: rest=3,2 4,5|nested=1,2 3|empty=9,0
// @xfail(raiser): the Raiser VM cannot evaluate msGenericArrayPush, the rest accumulator; `const [a, ...r] = src` fails the same way
function run(): void {
	let a: int32 = 0;
	let r: int32[] = [0];
	const src: int32[] = [3, 4, 5];
	[a, ...r] = src;
	let b: int32 = 0;
	let c: int32 = 0;
	let rest: int32[] = [];
	let row: int32[] = [];
	const grid: int32[][] = [[1], [2, 3]];
	[row, rest] = grid;
	[b] = row;
	let tail: int32[] = [];
	[c, ...tail] = rest;
	let e: int32 = 0;
	let none: int32[] = [1, 2];
	const one: int32[] = [9];
	[e, ...none] = one;
	console.log("rest=" + a.toString() + "," + r.length.toString() + " " + r[0].toString() + "," + r[1].toString()
		+ "|nested=" + b.toString() + "," + c.toString() + " " + tail[0].toString()
		+ "|empty=" + e.toString() + "," + none.length.toString());
}
run();
