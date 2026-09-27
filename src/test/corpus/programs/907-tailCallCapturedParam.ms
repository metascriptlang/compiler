// @stdout: ints=3,2,1,|refs=tz3,txb32,txxb21,|deep=2|guarded=4
// @xfail(raiser): raiser runtime error: call stack overflow (depth 1024)
class Box { s: string = ""; constructor(s: string) { this.s = s; } }
function build(n: int32, acc: (() => int32)[]): (() => int32)[] {
	if (n == 0) return acc;
	acc.push(() => n);
	return build(n - 1, acc);
}
function labels(n: int32, tag: string, b: Box, acc: (() => string)[]): (() => string)[] {
	if (n == 0) return acc;
	acc.push(() => tag + b.s + n.toString());
	return labels(n - 1, tag + "x", new Box("b" + n.toString()), acc);
}
function deep(n: int32, s: string): int32 {
	if (n == 0) return s.length;
	const f = () => s.length;
	return deep(n - 1, s + (f() > 1000000 ? "y" : ""));
}
function guarded(n: int32, k: int32): int32 {
	if (n == 0) return k;
	const probe = (): int32 => n + k;
	if (probe() > 100) return -1;
	return guarded(n - 1, k + 1);
}
function run(): void {
	let ints = "";
	for (const f of build(3, [])) { ints = ints + f().toString() + ","; }
	let refs = "";
	for (const f of labels(3, "t", new Box("z"), [])) { refs = refs + f() + ","; }
	console.log("ints=" + ints + "|refs=" + refs + "|deep=" + deep(1000000, "ab").toString() + "|guarded=" + guarded(4, 0).toString());
}
run();
