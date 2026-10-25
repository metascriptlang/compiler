import { evalSourceFull } from "../../codegen/raiser/eval";

const decls = "enum K { A = 5, B = 9 }"
	+ " struct Pair = match (ok: boolean) { true => { value: int32 }, false => { error: int32 } };"
	+ " struct Tagged = match (kind: K) { K.A => { count: int32 }, K.B => { items: Vec<int32> } };"
	+ " struct Left { x: int32 } struct Right { y: int32 }"
	+ " struct Sided = match (kind: K) { K.A => { side: Left }, K.B => { side: Right } };"
	+ " struct Holder { pair: Pair; n: int32 }";

function ran(body: string): string {
	const result = evalSourceFull(decls + " " + body);
	return result.lastError == "" ? `${result.lastResult.intVal}` : "error: " + result.lastError;
}

test "raiser value union: a const copy of a boolean-disc union owns its payload" {
	assert ran("const a: Pair = { ok: true, value: 1 }; let b = a; if (b.ok) b.value = 2; return a.ok ? a.value * 10 + (b.ok ? b.value : 0) : 0;") == "12";
}

test "raiser value union: an enum disc with explicit member values selects its arm" {
	assert ran("const a: Tagged = { kind: K.B, items: [1, 2] }; let b = a; if (b.kind == K.B) b.items[0] = 7; return a.kind == K.B ? a.items[0] * 10 + (b.kind == K.B ? b.items[0] : 0) : 0;") == "17";
	assert ran("const a: Tagged = { kind: K.A, count: 4 }; let b = a; if (b.kind == K.A) b.count = 6; return a.kind == K.A ? a.count * 10 + (b.kind == K.A ? b.count : 0) : 0;") == "46";
}

test "raiser value union: a field two arms share under different struct types copies by its own arm" {
	assert ran("const a: Sided = { kind: K.A, side: { x: 1 } }; let b = a; if (b.kind == K.A) b.side.x = 2; return a.kind == K.A ? a.side.x * 10 + (b.kind == K.A ? b.side.x : 0) : 0;") == "12";
	assert ran("const a: Sided = { kind: K.B, side: { y: 3 } }; let b = a; if (b.kind == K.B) b.side.y = 4; return a.kind == K.B ? a.side.y * 10 + (b.kind == K.B ? b.side.y : 0) : 0;") == "34";
}

test "raiser value union: an array literal element owns the union it was made from" {
	assert ran("const a: Pair = { ok: true, value: 1 }; const xs: Pair[] = [a]; if (xs[0].ok) xs[0].value = 2; return a.ok ? a.value * 10 + (xs[0].ok ? xs[0].value : 0) : 0;") == "12";
}

test "raiser value union: assigning a union over another arm replaces it with a copy" {
	assert ran("const a: Pair = { ok: true, value: 1 }; let b: Pair = { ok: false, error: 9 }; b = a; if (b.ok) b.value = 2; return a.ok ? a.value * 10 + (b.ok ? b.value : 0) : 0;") == "12";
}

test "raiser value union: assigning a holder over a held one copies the union field" {
	assert ran("const a: Holder = { pair: { ok: true, value: 1 }, n: 1 }; let b: Holder = { pair: { ok: false, error: 9 }, n: 2 }; b = a; if (b.pair.ok) b.pair.value = 2; return a.pair.ok ? a.pair.value * 10 + (b.pair.ok ? b.pair.value : 0) : 0;") == "12";
}

test "raiser value union: a union held by a struct is copied with its holder" {
	assert ran("const h: Holder = { pair: { ok: true, value: 1 }, n: 1 }; let g = h; if (g.pair.ok) g.pair.value = 2; return h.pair.ok ? h.pair.value * 10 + (g.pair.ok ? g.pair.value : 0) : 0;") == "12";
}
