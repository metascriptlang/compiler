// @skip-js: C-only by design: user lifecycle hooks run where the DRC runs; JS has no destructors
// @stdout: 2 4 7 -9 14 closed: 1 3 5 8 12.
// @stdout: closed: 1 3 5 8 12 14 10 7 4 2.

struct R { id: int32; }
let closed = "closed:";
function onDestroy(this r: R): void { if (r.id != 0) closed += ` ${r.id}`; }
function mk(id: int32): R { return { id: id }; }

type RU = R | int32;
type RW = R | string | null;
type RN = R | int32 | null;
struct Box { r: RU; }

function idU(u: RU): int32 {
	if (typeof u == "number") return -u;
	return u.id;
}

function idW(w: RW): int32 {
	if (w == null) return 0;
	if (typeof w == "string") return -1;
	return w.id;
}

function idN(n: RN): int32 {
	if (n == null) return 0;
	if (typeof n == "number") return -n;
	return n.id;
}

function moves(): void {
	let u: RU = mk(1);
	u = 5;
	u = mk(2);
	let w: RW = mk(3);
	w = "s";
	w = null;
	w = mk(4);
	let n: RN = mk(5);
	n = null;
	n = 6;
	n = mk(7);
	const arr: RU[] = [mk(8), 9, mk(10)];
	arr[0] = 11;
	let b: Box = { r: mk(12) };
	b.r = 13;
	b.r = mk(14);
	console.log(`${idU(u)} ${idW(w)} ${idN(n)} ${idU(arr[1])} ${idU(b.r)} ${closed}.`);
}

moves();
console.log(`${closed}.`);
