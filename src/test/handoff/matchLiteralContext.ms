// Checker — a match used as a value gives its arms the contextual literal type, as a conditional's branches get it

import { strictErrorCount, hasError } from "./helpers";

const SIDE = "type Side = \"left\" | \"right\";\ntype Key = \"a\" | \"b\";\n";

test "string literal arms fit a literal union return type" {
	assert strictErrorCount(SIDE + "function f(k: Key): Side { return match (k) { \"a\" => \"left\", _ => \"right\" }; }") == 0;
}

test "string literal arms fit a literal union initialiser over an enum subject" {
	assert strictErrorCount(SIDE + "enum E { A, B }\nfunction f(e: E): void { const s: Side = match (e) { E.A => \"left\", E.B => \"right\" }; }") == 0;
}

test "block tail arms fit a literal union" {
	assert strictErrorCount(SIDE + "function f(k: Key): Side { return match (k) { \"a\" => { const x = 1; \"left\" }, _ => \"right\" }; }") == 0;
}

test "struct field arms fit a literal union field" {
	assert strictErrorCount(SIDE + "struct H { side: Side; }\nfunction f(k: Key): H { return match (k) { \"a\" => ({ side: \"left\" }), _ => ({ side: \"right\" }) }; }") == 0;
}

test "a literal outside the union is still refused" {
	assert hasError(SIDE + "function f(k: Key): Side { return match (k) { \"a\" => \"up\", _ => \"right\" }; }", "is not assignable to type");
}

test "a wrong literal in one block tail arm is still refused" {
	assert hasError(SIDE + "function f(k: Key): Side { return match (k) { \"a\" => { const x = 1; \"up\" }, _ => \"right\" }; }", "is not assignable to type");
}

test "a Maybe expected type keeps taking literal arms" {
	assert strictErrorCount(SIDE + "function f(k: Key): Side | null { return match (k) { \"a\" => \"left\", _ => null }; }") == 0;
}
