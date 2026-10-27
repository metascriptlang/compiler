// @stdout: 1 9
// @stdout: 0 7 2
// @stdout: 4 0 4
// @exit: 0

struct Pt { x: int32; y: int32; }

function setSized(out a: int32[4]): void { a = [0, 7, 0, 2]; }
function setPts(out a: Pt[2]): void { a = [{ x: 0, y: 0 }, { x: 0, y: 4 }]; }
function fill(a: int32[4]): int32[4] {
	let b = a;
	b[0] = 4;
	return b;
}

function main(): void {
	const a: int32[4] = [1, 2, 3, 4];
	let b = a;
	b[0] = 9;
	console.log(`${a[0]} ${b[0]}`);
	let c: int32[4];
	setSized(out c);
	console.log(`${c[0]} ${c[1]} ${c[3]}`);
	let p: Pt[2];
	setPts(out p);
	const f = fill(c);
	console.log(`${f[0]} ${c[0]} ${p[1].y}`);
}
main();
