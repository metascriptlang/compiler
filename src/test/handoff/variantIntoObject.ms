import { strictErrorCount, hasError } from "./helpers";

const pairDecl = "struct Pair = match (ok: boolean) { true => { value: string }, false => { error: string } };\n"
	+ "function mkPair(g: boolean): Pair { if (g) return { ok: true, value: \"lib\" }; return { ok: false, error: \"no\" }; }\n"
	+ "const p = mkPair(true);\n";
const pairRefusal = "'p' is a value of 'Pair' (ok: true); '{ ok: true; value: string }' takes an object (a reference). "
	+ "Copy it with '{ ...p }', take the parameter as 'Pair', or declare 'Pair' with 'type' to share it.";
const takeOk = "function f(x: { ok: true; value: string }): string { return x.value; }\n";

test "a narrowed match variant is refused where an object parameter is expected" {
	assert hasError(pairDecl + takeOk + "if (p.ok) f(p);", pairRefusal);
}

test "a narrowed match variant is refused where an interface parameter is expected" {
	const src = pairDecl + "interface HasValue { value: string }\nfunction f(x: HasValue): string { return x.value; }\nif (p.ok) f(p);";
	assert hasError(src, "'p' is a value of 'Pair' (ok: true); 'HasValue' takes an object (a reference). Copy it with '{ ...p }'");
}

test "a narrowed match variant is refused in a typed local, an assignment and a return" {
	assert hasError(pairDecl + "if (p.ok) { const q: { ok: true; value: string } = p; }", pairRefusal);
	assert hasError(pairDecl + "if (p.ok) { let q: { ok: true; value: string } = { ok: true, value: \"x\" }; q = p; }", pairRefusal);
	assert hasError(pairDecl + "function g(): { ok: true; value: string } { if (p.ok) return p; return { ok: true, value: \"x\" }; }", pairRefusal);
}

test "a narrowed match variant is refused as an element of an object array" {
	assert hasError(pairDecl + "const a: { ok: true; value: string }[] = [];\nif (p.ok) a.push(p);", pairRefusal);
	assert hasError(pairDecl + "if (p.ok) { const a: { ok: true; value: string }[] = [p]; }", pairRefusal);
}

test "a narrowed match variant is refused where the discriminant is written wider" {
	assert hasError(pairDecl + "function f(x: { ok: boolean; value: string }): string { return x.value; }\nif (p.ok) f(p);",
		"'p' is a value of 'Pair' (ok: true); '{ ok: boolean; value: string }' takes an object (a reference).");
}

test "a narrowed enum match variant is refused where an object parameter is expected" {
	const src = "enum K { A, B }\nstruct S = match (kind: K) { K.A => { r: string }, K.B => { n: int32 } };\n"
		+ "function mkS(g: boolean): S { if (g) return { kind: K.A, r: \"lib\" }; return { kind: K.B, n: 3 }; }\n"
		+ "const s = mkS(true);\nfunction f(x: { kind: K.A; r: string }): string { return x.r; }\nif (s.kind == K.A) f(s);";
	assert hasError(src, "'s' is a value of 'S' (kind: K.A); '{ kind: K.A; r: string }' takes an object (a reference). "
		+ "Copy it with '{ ...s }', take the parameter as 'S', or declare 'S' with 'type' to share it.");
}

test "a narrowed Result is refused where an object is expected and is not told to declare it with type" {
	const decl = "function mkResult(g: boolean): Result<int32, string> { if (g) return Result.ok(7); return Result.err(\"no\"); }\nconst r = mkResult(true);\n";
	const refusal = "'r' is a value of 'Result<int32, string>' (ok: true); '{ ok: true; value: int32 }' takes an object (a reference). "
		+ "Copy it with '{ ...r }', take the parameter as 'Result<int32, string>'.";
	assert hasError(decl + "function f(x: { ok: true; value: int32 }): int32 { return x.value; }\nif (r.ok) f(r);", refusal);
	assert hasError(decl + "if (r.ok) { const q: { ok: true; value: int32 } = r; }", refusal);
}

test "a narrowed variant of a type union is refused without the hint to declare it with type" {
	const src = pairDecl.replace("struct Pair", "type Pair") + takeOk + "if (p.ok) f(p);";
	assert hasError(src, "takes an object (a reference). Copy it with '{ ...p }', take the parameter as 'Pair'.");
	assert !hasError(src, "to share it");
}

test "a narrowed variant is copied into an object, kept as its union or serialized without a refusal" {
	assert strictErrorCount(pairDecl + takeOk + "if (p.ok) f({ ...p });") == 0;
	assert strictErrorCount(pairDecl + "function f(x: Pair): boolean { return x.ok; }\nif (p.ok) f(p);") == 0;
	assert strictErrorCount(pairDecl + "function id<T>(x: T): T { return x; }\nif (p.ok) { const q = id(p); JSON.stringify(p); }") == 0;
}
