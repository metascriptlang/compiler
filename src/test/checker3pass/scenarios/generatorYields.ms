import { checkOnly } from "../helpers";

const SRC_NO_YIELD = `
function* nothing() { }
`;

const SRC_RETURN_VALUE = `
function* valued() { yield 1; return 2; }
class G { *items() { yield "a"; return "b"; } }
`;

const SRC_YIELD_MISMATCH = `
function* g(): Iterator<int32> { yield "s"; }
`;

const SRC_INFERRED = `
function* g() { yield 1; yield 2; }
const it = g();
const n: int32 = it.next().value;
`;

test "a generator with no yielded value cannot infer what it yields" {
	const text = checkOnly(SRC_NO_YIELD).errors.join("\n");
	assert text.contains("cannot infer what generator 'nothing' yields: it has no 'yield' with a value; annotate its return type as Iterator<T>"), "an empty generator must be refused at its declaration: " + text;
}

test "an unannotated generator's return carries no value" {
	const errors = checkOnly(SRC_RETURN_VALUE).errors;
	let refused = 0;
	for (const e of errors) {
		if (e.contains("a generator's 'return' ends it and carries no value")) refused += 1;
	}
	assert refused == 2, "both returns with a value must be refused: " + errors.join("\n");
}

test "a yield is checked against the declared element type" {
	const text = checkOnly(SRC_YIELD_MISMATCH).errors.join("\n");
	assert text.contains("Type 'string' is not assignable to type 'int32'"), "yield \"s\" into Iterator<int32> must be refused: " + text;
}

test "an unannotated generator's next() reads the yielded type" {
	const result = checkOnly(SRC_INFERRED);
	assert result.errors.length == 0, "the yields type next().value: " + result.errors.join("\n");
}
