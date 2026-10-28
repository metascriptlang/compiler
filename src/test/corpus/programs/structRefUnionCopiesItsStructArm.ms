// @stdout: 1 1 9|1 1|r:x r:x
// @xfail(js): the JS backend aliases a struct arm of a union on copy, so a write to the source shows in the copy (prints 5 5, on main too)
// @xfail(esm): the JS backend aliases a struct arm of a union on copy, so a write to the source shows in the copy (prints 5 5, on main too)
// note: copying a union of a value struct and a ref member copies the struct arm, so a write to the copy leaves the source and the array element alone, while the ref arm stays shared
struct S { kind: "s"; n: int32 }
interface R { kind: "r"; name: string }
type U = S | R;

function readN(u: U): string {
	if (u.kind === "s") return u.n.toString();
	return "r";
}

function name(u: U): string {
	if (u.kind === "r") return "r:" + u.name;
	return "s";
}

function main(): void {
	let a: S = { kind: "s", n: 1 };
	const u: U = a;
	const arr: U[] = [u];
	let s = arr[0] as S;
	s.n = 9;
	const viaA = readN(u);
	const viaArr = readN(arr[0]);
	const copy: U = arr[0];
	a.n = 5;
	const r: R = { kind: "r", name: "x" };
	const ur: U = r;
	const rs: U[] = [ur];
	console.log(`${viaA} ${viaArr} ${s.n}|${readN(copy)} ${readN(arr[0])}|${name(rs[0])} ${name(ur)}`);
}
main();
