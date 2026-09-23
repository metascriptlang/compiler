import { compileToC, compileToCWithStd } from "../helpers";

const PRELUDE = "enum E { A, B, C, D } const s: BitSet<E> = E.A | E.C; const t: BitSet<E> = E.C | E.D; ";

function cFor(body: string): string {
	const c = compileToC(PRELUDE + body);
	if (!c.ok) return "";
	return c.value;
}

function errorFor(body: string): string {
	const c = compileToC(PRELUDE + body);
	if (c.ok) return "";
	return c.error;
}

test "difference is the word masked by the complement" {
	const c = cFor("const d = s.difference(t); console.log(d.has(E.A));");
	assert c != "";
	assert c.contains("& (~");
	assert !c.contains("difference__");
}

test "the three familiar operators stay the shorthand" {
	const c = cFor("const u = s | t; const i = s & t; const x = s ^ t; console.log(u.has(E.D), i.has(E.C), x.has(E.A));");
	assert c != "";
	assert !c.contains("union__");
	assert !c.contains("intersection__");
}

test "a subset test compares the masked word against zero" {
	const c = cFor("console.log(s.isSubsetOf(t), s.isSupersetOf(t), s.isDisjointFrom(t));");
	assert c != "";
	assert !c.contains("isSubsetOf__");
}

test "size counts the bits of the word" {
	const c = cFor("console.log(s.size());");
	assert c != "";
	assert c.contains("msSetCard32(");
}

test "the complement of a set is rejected" {
	assert errorFor("const n = ~s; console.log(n.has(E.A));").contains("bitwise NOT '~' has no meaning on a set");
}

test "a set hashes by its value, not by its address" {
	const c = compileToCWithStd(PRELUDE + "console.log(s.hash());");
	assert c.ok;
	assert c.value.contains("msSetHashWord(");
	assert !c.value.contains("msPtrBits");
}
