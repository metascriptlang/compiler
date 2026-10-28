// @stdout: s3 n7 s3 s9|s3 n7|1 3
// note: a union of a value struct and a scalar is passed, returned, stored in an array and copied; the copy owns its own struct arm and releases it, and the scalar arm needs no release
struct S { c: int32 }

function show(a: S | int32): string {
	if (typeof a === "number") return "n" + a.toString();
	return "s" + a.c.toString();
}

function id(a: S | int32): S | int32 {
	return a;
}

function main(): void {
	let s: S = { c: 3 };
	const u: S | int32 = s;
	const arr: (S | int32)[] = [u, 7];
	const back = id(arr[0]);
	let w = arr[0] as S;
	w.c = 9;
	s.c = 3;
	const copy: S | int32 = arr[1];
	console.log(`${show(u)} ${show(copy)} ${show(back)} ${show(w)}|${show(arr[0])} ${show(arr[1])}|1 ${s.c}`);
}
main();
