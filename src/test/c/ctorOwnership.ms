import { compileToC } from "../helpers";

function bodyOf(code: string, name: string, marker: string): string {
	for (const line of code.split("\n")) {
		const at = line.indexOf(marker);
		if (at < 0 || !line.endsWith(" {") || line.indexOf(" " + name + "__") < 0) continue;
		const start = code.indexOf(line + "\n");
		return code.slice(start, code.indexOf("\n}", start));
	}
	return "";
}

function initBody(code: string, className: string): string {
	return bodyOf(code, className, "_init(");
}

function routineBody(code: string, name: string): string {
	return bodyOf(code, name, "(");
}

function occurrences(haystack: string, needle: string): int32 {
	return (haystack.split(needle).length - 1) as int32;
}

const TREE_SRC = `
class Node {
	left: Node | null;
	right: Node | null;
	constructor(left: Node | null, right: Node | null) { this.left = left; this.right = right; }
}
function bottomUp(d: int32): Node {
	if (d > 0) return new Node(bottomUp(d - 1), bottomUp(d - 1));
	return new Node(null, null);
}
console.log(String(bottomUp(2).left == null));
`;

test "ctorOwnership: a constructor moves its arguments into the fresh fields with no incref and no old-value destroy" {
	const result = compileToC(TREE_SRC);
	assert result.ok, result.error;
	const body = initBody(result.value, "Node");
	assert body != "";
	assert !body.contains("Incref");
	assert !body.contains("oldField");
	assert occurrences(body, "msPtrWasMoved(left)") == 1;
	assert occurrences(body, "msPtrWasMoved(right)") == 1;
}

test "ctorOwnership: the caller of a constructor that cannot raise carries no error check" {
	const result = compileToC(TREE_SRC);
	assert result.ok, result.error;
	const start = result.value.indexOf("bottomUp__");
	assert start >= 0;
	assert !result.value.slice(result.value.indexOf("\nMS_LIB_PRIVATE Node", start), result.value.indexOf("\n}", start)).contains("msErr");
}

const FIELDS_SRC = `
class Leaf { name: string; constructor(name: string) { this.name = name; } }
class Twice { f: Leaf; constructor(a: Leaf, b: Leaf) { this.f = a; this.f = b; } }
class AfterUse {
	f: Leaf;
	g: Leaf;
	constructor(a: Leaf) { this.f = a; this.g = this.f; this.f = a; }
}
class Kept { f: Leaf; constructor(a: Leaf) { this.f = a; } }
function run(): void {
	const l = new Leaf("l");
	const t = new Twice(l, l);
	const u = new AfterUse(l);
	const k = new Kept(l);
	console.log(l.name + t.f.name + u.f.name + k.f.name);
}
run();
`;

test "ctorOwnership: only the first write of a field skips destroying the old value" {
	const result = compileToC(FIELDS_SRC);
	assert result.ok, result.error;
	assert occurrences(initBody(result.value, "Twice"), "msDecref(") == 1;
	assert occurrences(initBody(result.value, "Kept"), "dollaroldField") == 0;
}

test "ctorOwnership: a field written after the constructor read `this` destroys what it replaces" {
	const result = compileToC(FIELDS_SRC);
	assert result.ok, result.error;
	assert occurrences(initBody(result.value, "AfterUse"), "msDecref(") == 2;
}

test "ctorOwnership: an argument still used after the new is copied into the constructor" {
	const result = compileToC(FIELDS_SRC);
	assert result.ok, result.error;
	assert occurrences(routineBody(result.value, "run"), "msIncref(") == 4;
}
