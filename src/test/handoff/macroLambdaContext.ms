import { compileToCWithStd } from "../helpers";

const head = `import { ArrowFunctionData, Node, NodeKind, createNodeAt } from "std/meta";
struct Card { column: string; owner: uint32; }
class Table<R, K> { rows: R[] = []; key: K | null = null; }
macro tag<R, K>(this t: Table<R, K>, f: (row: R) => boolean): Node { return createNodeAt(NodeKind.StringLiteral, { value: "tagged" }, f.location); }
const cards = new Table<Card, string>();
`;

test "macro lambda: the lambda is typed from the receiver, dot call and bare call" {
	const dot = compileToCWithStd(head + `const v: string = cards.tag(c => c.column == "todo");`);
	assert dot.ok, dot.ok ? "" : dot.error;
	const bare = compileToCWithStd(head + `const v: string = tag(cards, c => c.owner == 1);`);
	assert bare.ok, bare.ok ? "" : bare.error;
}

test "macro lambda: a wrong field is an error at the lambda before expansion" {
	const result = compileToCWithStd(head + `const v: string = cards.tag(c => c.colum == "todo");`);
	assert !result.ok && result.error.includes("colum"), result.ok ? "accepted" : result.error;
}

test "macro lambda: a receiver that does not bind the type parameters is a mismatch" {
	const result = compileToCWithStd(head + `const v: string = tag(5, c => true);`);
	assert !result.ok && result.error.includes("Argument type mismatch in 'tag'"), result.ok ? "accepted" : result.error;
}

test "macro lambda: a lambda of the wrong result type is a mismatch" {
	const result = compileToCWithStd(head + `const v: string = cards.tag(c => c.column);`);
	assert !result.ok, "accepted";
}

test "macro lambda: a formal naming nothing is refused at the call" {
	const result = compileToCWithStd(head + `macro bad<R>(t: Table<R, string>, f: (row: Rwo) => boolean): Node { return t; }\nconst v = bad(cards, c => true);`);
	assert !result.ok && result.error.includes("does not resolve"), result.ok ? "accepted" : result.error;
}

test "macro lambda: inside a generic function the call defers and expands once the type is known" {
	const result = compileToCWithStd(head + `function viaTable<T>(t: Table<T, string>): string { return t.tag(r => true); }\nconst v: string = viaTable<Card>(cards);`);
	assert result.ok, result.ok ? "" : result.error;
}

test "macro lambda: an untyped Node formal checks its argument with no expected type" {
	const result = compileToCWithStd(head + `macro raw(fn: Node): Node { return createNodeAt(NodeKind.StringLiteral, { value: "raw" }, fn.location); }\nconst v: string = raw((c) => c);`);
	assert result.ok, result.ok ? "" : result.error;
}
