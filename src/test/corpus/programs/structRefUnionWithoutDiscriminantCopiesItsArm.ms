// @stdout: 1 1 9|1 1|c:x c:x
// @xfail(js): the JS backend aliases a struct arm of a union on copy, so a write to the source shows in the copy
// @xfail(esm): the JS backend aliases a struct arm of a union on copy, so a write to the source shows in the copy
// note: a struct arm with no literal discriminant is told from the class arm by the class test
struct S { n: int32 }
class Foo { name: string; constructor(name: string) { this.name = name; } }
type U = S | Foo;

function readN(u: U): string {
	if (u instanceof Foo) return "c:" + u.name;
	return u.n.toString();
}

function main(): void {
	let a: S = { n: 1 };
	const u: U = a;
	const arr: U[] = [u];
	let s = arr[0] as S;
	s.n = 9;
	const viaA = readN(u);
	const viaArr = readN(arr[0]);
	const copy: U = arr[0];
	a.n = 5;
	const f: U = new Foo("x");
	const fs: U[] = [f];
	console.log(`${viaA} ${viaArr} ${s.n}|${readN(copy)} ${readN(arr[0])}|${readN(fs[0])} ${readN(f)}`);
}
main();
