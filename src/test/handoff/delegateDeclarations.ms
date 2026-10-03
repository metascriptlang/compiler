import { checkProjectDiagnostics, compileToCWithStd, MapEntry } from "../helpers";

const BASE = "struct Account { address: uint64; lamports: uint64; }\nfunction key(this a: Account): uint64 { return a.address * 2; }\ntype Signer = distinct Account;\n";
const LOCAL = "const a: Account = { address: 21, lamports: 5 };\n";
const DELEGATED = "@delegate function key(this s: Signer): uint64;\n@delegate type Payer = distinct Account;\n" + LOCAL + "const k: uint64 = (a as Signer).key() + key(a as Signer);\nconst l: uint64 = (a as Payer).lamports;\n";

function reported(declarations: string): string[] {
	const entries: MapEntry[] = [{ entryPath: "src/main.ms", entrySource: BASE + declarations }];
	const messages: string[] = [];
	for (const message of checkProjectDiagnostics(entries, "src/main.ms")) {
		if (!message.endsWith("is declared but never used")) messages.push(message);
	}
	return messages;
}

test "delegateDeclarations: a delegating function names a distinct parameter, a base function of its name and the base return type" {
	const cases = [
		{ name: "a distinct parameter, a base function of that name and its return type are accepted", source: "@delegate function key(this s: Signer): uint64;\n", errors: 0 },
		{ name: "a base function under another name is accepted the same way", source: "function tag(this a: Account): uint64 { return 1; }\n@delegate function tag(this s: Signer): uint64;\n", errors: 0 },
		{ name: "a parameter that is not distinct has nothing to delegate", source: "@delegate function key(this a: Account): uint64;\n", errors: 1 },
		{ name: "a name no base function carries has nothing to delegate to", source: "@delegate function tag(this s: Signer): uint64;\n", errors: 1 },
		{ name: "a return type other than the base function's is refused", source: "@delegate function key(this s: Signer): int32;\n", errors: 1 },
	];
	for (const item of cases) {
		const messages = reported(item.source);
		assert messages.length == item.errors, item.name + ": " + messages.join(" | ");
	}
}

test "delegateDeclarations: a delegating declaration has no body and no arguments and sits on a function or a distinct type" {
	const cases = [
		{ name: "a delegating function without a body is accepted", source: "@delegate function key(this s: Signer): uint64;\n", errors: 0 },
		{ name: "a delegating distinct type is accepted", source: "@delegate type Payer = distinct Account;\n", errors: 0 },
		{ name: "a body would stand in for the base function it should reuse", source: "@delegate function key(this s: Signer): uint64 { return 1; }\n", errors: 1 },
		{ name: "an argument is refused", source: "@delegate(1) function key(this s: Signer): uint64;\n", errors: 1 },
		{ name: "a type that is not distinct has no base to expose", source: "@delegate type Plain = Account;\n", errors: 1 },
		{ name: "a variable has no base to delegate", source: "@delegate const k = 1;\n", errors: 1 },
	];
	for (const item of cases) {
		const messages = reported(item.source);
		assert messages.length == item.errors, item.name + ": " + messages.join(" | ");
	}
}

test "delegateDeclarations: delegation does not reach a generic base" {
	const cases = [
		{ name: "a base function that names no type parameter is accepted", source: "type Heap = distinct int32[];\nfunction heapLength(a: int32[]): int32 { return a.length as int32; }\n@delegate function heapLength(h: Heap): int32;\n", errors: 0 },
		{ name: "a generic base function is refused", source: "type Heap<T> = distinct T[];\nfunction heapLength<T>(a: T[]): int32 { return a.length as int32; }\n@delegate function heapLength<T>(h: Heap<T>): int32;\n", errors: 1 },
	];
	for (const item of cases) {
		const messages = reported(item.source);
		assert messages.length == item.errors, item.name + ": " + messages.join(" | ");
	}
}

test "delegateDeclarations: only the @delegate spelling declares delegation" {
	const current = reported("@delegate function key(this s: Signer): uint64;\n");
	assert current.length == 0, current.join(" | ");
	const former = reported("@borrow function key(this s: Signer): uint64;\n");
	assert former.length == 1, former.join(" | ");
}

test "delegateDeclarations: a distinct type has neither the methods nor the fields of its base without a delegating declaration" {
	const cases = [
		{ name: "a method of the base is not called through the distinct type", source: LOCAL + "const k = (a as Signer).key();\n", errors: 1 },
		{ name: "a field of the base is not read through the distinct type", source: LOCAL + "const l = (a as Signer).lamports;\n", errors: 1 },
	];
	for (const item of cases) {
		const messages = reported(item.source);
		assert messages.length == item.errors, item.name + ": " + messages.join(" | ");
	}
}

test "delegateDeclarations: a delegated function and a delegated distinct type compile" {
	const messages = reported(DELEGATED);
	assert messages.length == 0, messages.join(" | ");
	const result = compileToCWithStd(BASE + DELEGATED);
	assert result.ok, result.ok ? "" : result.error;
}
