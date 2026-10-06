import { Node, NodeKind, bindSym, getImpl } from "std/meta";

function signer(value: Node, context: Node): Node { return value; }
function seeds(first: string, second: string): void {}
function bump(value: int32): void {}

struct Vault {
	@signer owner: int32;
	@seeds("vault", owner) @bump(vault.bump) bump: int32;
}

interface Slot {
	@signer id: int32;
	label: string;
}

struct Pair<T> {
	@signer first: T;
	second: T;
}

macro decorators(): Node {
	const shape = getTypeArg();
	const decl = getImpl(bindSym(shape.typExprTypeName))!;
	let text = "";
	for (let i = 0; i < decl.interfaceFields.length; i += 1) {
		text = text + decl.interfaceFields[i] + "=";
		for (const dec of decl.interfaceFieldDecorators[i]) {
			text = text + dec.macroName + "/" + dec.macroArgs.length.toString() + ",";
		}
		text = text + ";";
	}
	return { kind: NodeKind.StringLiteral, line: shape.line, column: shape.column, value: text };
}

function localDecorated(): int32 {
	struct Local {
		@signer value: int32;
		@bump(value) twice: int32;
	}
	const l: Local = { value: 4, twice: 8 };
	return l.value + l.twice;
}

test "struct field decorators: a decorated struct copies, compares and spreads like a plain one" {
	const a: Vault = { owner: 1, bump: 2 };
	const b: Vault = { ...a, bump: 3 };
	assert a.owner == b.owner;
	assert a.bump == 2 && b.bump == 3;
	assert a != b;
	const c: Vault = a;
	assert c == a;
}

test "struct field decorators: an interface with a decorated field builds from an object literal" {
	const s: Slot = { id: 7, label: "seven" };
	assert s.id == 7 && s.label == "seven";
}

test "struct field decorators: a generic struct with a decorated field instantiates" {
	const p: Pair<int64> = { first: 5, second: 6 };
	assert p.first + p.second == 11;
	const q: Pair<string> = { first: "a", second: "b" };
	assert q.first + q.second == "ab";
}

test "struct field decorators: a struct declared in a function body keeps its decorated fields" {
	assert localDecorated() == 12;
}

test "struct field decorators: a macro reads each field's decorator names and argument counts" {
	assert decorators<Vault>() == "owner=signer/0,;bump=seeds/2,bump/1,;";
	assert decorators<Slot>() == "id=signer/0,;label=;";
}
