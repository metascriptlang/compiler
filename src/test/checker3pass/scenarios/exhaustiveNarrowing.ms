import { checkOnly } from "../helpers";

const TYPES = `
enum En { A, B, C }
type Lit = "n" | "e";
type Disc = { kind: "s", a: int32 } | { kind: "t", b: int32 } | { kind: "u", c: int32 };
function assertNever(x: never): string { return "x"; }
`;

function errorsOf(body: string): string {
	return checkOnly(TYPES + body).errors.join("\n");
}

test "an if chain that tests every member leaves never" {
	assert errorsOf("function f(e: En): int32 { if (e === En.A) { return 1; } if (e == En.B) { return 2; } if (e === En.C) { return 3; } const x: never = e; return 0; }\n") == "";
	assert errorsOf("function f(e: Lit): int32 { if (e === \"n\") { return 1; } if (e === \"e\") { return 2; } const x: never = e; return 0; }\n") == "";
	assert errorsOf("function f(d: Disc): string { if (d.kind === \"s\") { return \"s\"; } if (d.kind === \"t\") { return \"t\"; } if (d.kind === \"u\") { return \"u\"; } return assertNever(d); }\n") == "";
}

test "a chain that misses a member leaves that member" {
	const en = errorsOf("function f(e: En): int32 { if (e === En.A) { return 1; } if (e === En.B) { return 2; } const x: never = e; return 0; }\n");
	assert en.contains("not assignable to type 'never'"), en;
	const lit = errorsOf("function f(e: Lit): int32 { if (e === \"n\") { return 1; } const x: never = e; return 0; }\n");
	assert lit.contains("not assignable to type 'never'"), lit;
	const disc = errorsOf("function f(d: Disc): string { if (d.kind === \"s\") { return \"s\"; } if (d.kind === \"t\") { return \"t\"; } return assertNever(d); }\n");
	assert disc.contains("assertNever"), disc;
}

test "a remainder of an enum reads as the enum" {
	assert errorsOf("function show(e: En): int32 { return 1; }\nfunction f(e: En): int32 { if (e === En.A) { return 1; } return show(e); }\n") == "";
}

test "a switch without default that covers every member needs no ending return" {
	assert errorsOf("function f(e: En): int32 { switch (e) { case En.A: return 1; case En.B: return 2; case En.C: return 3; } }\n") == "";
	assert errorsOf("function f(e: Lit): int32 { switch (e) { case \"n\": return 1; case \"e\": return 2; } }\n") == "";
	assert errorsOf("function f(x: 1 | 2): int32 { switch (x) { case 1: return 1; case 2: return 2; } }\n") == "";
	assert errorsOf("function f(b: boolean): int32 { switch (b) { case true: return 1; case false: return 2; } }\n") == "";
}

test "a switch that misses a member still lacks an ending return" {
	const en = errorsOf("function f(e: En): int32 { switch (e) { case En.A: return 1; case En.B: return 2; } }\n");
	assert en.contains("lacks an ending return"), en;
	const lit = errorsOf("function f(e: Lit): int32 { switch (e) { case \"n\": return 1; } }\n");
	assert lit.contains("lacks an ending return"), lit;
	const wide = errorsOf("function f(s: string): int32 { switch (s) { case \"n\": return 1; case \"e\": return 2; } }\n");
	assert wide.contains("lacks an ending return"), wide;
	const broken = errorsOf("function f(e: Lit): int32 { switch (e) { case \"n\": return 1; case \"e\": break; } }\n");
	assert broken.contains("lacks an ending return"), broken;
}
