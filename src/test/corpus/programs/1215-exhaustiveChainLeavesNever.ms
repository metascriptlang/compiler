// @stdout: 3 2 u 2 pq
enum En { A, B, C }
type Lit = "n" | "e";
type Disc = { kind: "s", a: int32 } | { kind: "t", b: int32 } | { kind: "u", c: int32 };
type Flag = { ok: true, v: int32 } | { ok: false, e: string };
function enumChain(e: En): int32 {
	if (e === En.A) { return 1; }
	if (e == En.B) { return 2; }
	if (e === En.C) { return 3; }
	const x: never = e;
	return 0;
}
function litChain(e: Lit): int32 {
	if (e === "n") { return 1; }
	if (e === "e") { return 2; }
	const x: never = e;
	return 0;
}
function discChain(d: Disc): string {
	if (d.kind === "s") { return "s"; }
	if (d.kind === "t") { return "t"; }
	if (d.kind === "u") { return "u"; }
	const x: never = d;
	return "?";
}
function flagChain(f: Flag): string {
	if (f.ok) { return `${f.v}`; }
	if (!f.ok) { return f.e; }
	const x: never = f;
	return "?";
}
function partial(e: En): int32 {
	if (e === En.A) { return 10; }
	return e == En.B ? 20 : 30;
}
console.log(enumChain(En.C), litChain("e"), discChain({ kind: "u", c: 3 }), partial(En.A) + 2 - 10 + (partial(En.C) - 30), flagChain({ ok: false, e: "pq" }));
