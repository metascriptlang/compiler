import { checkOnly } from "../helpers";

const SRC_CONST_ARROWS = `
function make(): () => number {
	let n = 0;
	const a = (): number => { n += 1; return n < 3 ? b() : n; };
	const b = (): number => a();
	return a;
}
`;

const SRC_GAP = `
function make(): number {
	function a(): number { return b(); }
	const x = a();
	function b(): number { return 1; }
	return x;
}
`;

const SRC_UNANNOTATED = `
function make(): number {
	let n = 0;
	function a(): number { n += 1; return n < 3 ? b() : n; }
	function b() { return a(); }
	return a();
}
`;

const SRC_ADJACENT = `
function make(): number {
	let n = 0;
	function a(): number { n += 1; return n < 3 ? b() : n; }
	function b(): number { return a(); }
	function walk(k: int32) { if (k > 0) walk(k - 1); }
	walk(2);
	return a();
}
`;

test "a const arrow cannot call a const declared after it, and the error says why" {
	const text = checkOnly(SRC_CONST_ARROWS).errors.join("\n");
	assert text.contains("Undefined variable 'b': 'b' is declared later in this block, and a const or let is not visible before its declaration"), "a forward const reference must be refused with its rule: " + text;
}

test "a local function cannot call one declared after a statement that runs between them" {
	const text = checkOnly(SRC_GAP).errors.join("\n");
	assert text.contains("Undefined variable 'b': 'b' is declared later in this block, after a statement that runs first"), "a forward call across a statement must be refused with its rule: " + text;
}

test "a local function read before its declaration needs its return type written" {
	const text = checkOnly(SRC_UNANNOTATED).errors.join("\n");
	assert text.contains("'b' is used before its declaration is checked, so its return type cannot be inferred yet; annotate the return type of 'b'"), "an unannotated forward local must be refused: " + text;
}

test "adjacent local function declarations call each other" {
	const result = checkOnly(SRC_ADJACENT);
	assert result.errors.length == 0, "adjacent local functions must check: " + result.errors.join("\n");
}
