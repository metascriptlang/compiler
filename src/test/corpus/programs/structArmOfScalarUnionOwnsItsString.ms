// @stdout: s3
// @stdout: s2 s3 n6
// @stdout: s9
// @stdout: s8 s9 ty
// @stdout: s12
// @stdout: s11 s12 n13
// @stdout: n8
// @stdout: s16
// @stdout: s15
// @stdout: s16 s20 s20 tz
// @stdout: end

struct S { id: int32; s: string; }
function mk(id: int32): S { return { id: id, s: "s" + id.toString() }; }

type U = S | int32;
type W = S | string | null;
type N = S | int32 | null;
struct Holder { u: U; w: W; }

function showU(u: U): string {
	if (typeof u == "number") return "n" + u.toString();
	return u.s;
}

function showW(w: W): string {
	if (w == null) return "null";
	if (typeof w == "string") return "t" + w;
	return w.s;
}

function showN(n: N): string {
	if (n == null) return "null";
	if (typeof n == "number") return "n" + n.toString();
	return n.s;
}

function scalarArm(): void {
	let u: U = mk(1);
	u = 5;
	u = mk(2);
	const moved = u;
	u = mk(3);
	const kept: U = u;
	console.log(showU(u));
	u = 6;
	console.log(`${showU(moved)} ${showU(kept)} ${showU(u)}`);
}

function stringArm(): void {
	let w: W = mk(7);
	w = "x";
	w = null;
	w = mk(8);
	const moved = w;
	w = mk(9);
	const kept: W = w;
	console.log(showW(w));
	w = "y";
	console.log(`${showW(moved)} ${showW(kept)} ${showW(w)}`);
}

function nullableArm(): void {
	let n: N = mk(10);
	n = 4;
	n = null;
	n = mk(11);
	const moved = n;
	n = mk(12);
	const kept: N = n;
	console.log(showN(n));
	n = 13;
	console.log(`${showN(moved)} ${showN(kept)} ${showN(n)}`);
}

function slots(): void {
	const arr: U[] = [mk(14), 7, mk(15)];
	arr[0] = 8;
	arr[1] = mk(16);
	const first = arr[1];
	for (const x of arr) console.log(showU(x));
	let h: Holder = { u: mk(17), w: mk(18) };
	h.u = 19;
	h.u = mk(20);
	h.w = "z";
	const hu = h.u;
	console.log(`${showU(first)} ${showU(hu)} ${showU(h.u)} ${showW(h.w)}`);
}

scalarArm();
stringArm();
nullableArm();
slots();
console.log("end");
