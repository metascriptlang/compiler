import { Node, NodeKind } from "std/meta";

interface Alpha { a: int32; }
interface Beta { b: int32; c: int32; }
interface Wrapped<T> { inner: T; tag: int32; }

macro fieldNames(): Node {
	const t = getTypeArg();
	let names: string = "";
	if (t.kind === NodeKind.TypeObject) {
		let i = 0;
		while (i < t.typExprFieldNames.length) {
			if (i > 0) { names = names + ","; }
			names = names + t.typExprFieldNames[i];
			i = i + 1;
		}
	}
	return { kind: NodeKind.StringLiteral, line: 0, column: 0, value: names };
}

macro typeFree(): Node {
	return { kind: NodeKind.StringLiteral, line: 0, column: 0, value: "free" };
}

function namesIn<T>(): string { return fieldNames<T>(); }

test "one compiled macro body gives each explicit type argument its own expansion" {
	assert fieldNames<Alpha>() == "a";
	assert fieldNames<Beta>() == "b,c";
	assert fieldNames<Alpha>() == "a";
	assert fieldNames<Wrapped<Alpha>>() == "inner,tag";
}

test "an instance of a generic function expands the macro with its own type argument" {
	assert namesIn<Beta>() == "b,c";
	assert namesIn<Alpha>() == "a";
	assert namesIn<Wrapped<Beta>>() == "inner,tag";
}

test "a macro that never reads its type argument is unaffected by it" {
	assert typeFree<Alpha>() == "free";
	assert typeFree<Beta>() == "free";
	assert typeFree() == "free";
}
