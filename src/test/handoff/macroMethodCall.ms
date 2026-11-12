import { compileToCWithStd } from "../helpers";

const head = `import { Node, NodeKind, createNodeAt } from "std/meta";\n`;

test "macro receiver parameter: `this src` names the receiver inside the body" {
	const result = compileToCWithStd(head + `macro echo(this src: Node): Node { return src; }\nconst v: int32 = echo(5);`);
	assert result.ok, result.ok ? "" : result.error;
}

test "macro receiver parameter: only `this name` on the first parameter is accepted" {
	const cases = [
		`macro m(a: Node, this b: Node): Node { return a; }`,
		`macro m(this ref s: Node): Node { return s; }`,
		`macro m(this typeof Node): Node { return quote { 1 }; }`,
		`macro m(this: Node): Node { return quote { 1 }; }`,
	];
	for (const decl of cases) {
		const result = compileToCWithStd(head + decl);
		assert !result.ok, decl;
	}
}

const dotHead = head + `
class Table { name: string = "t"; }
macro twoM(this src: Node, a: Node): Node { return createNodeAt(NodeKind.StringLiteral, { value: "two" }, a.location); }
const table = new Table();
`;

test "dot call to a macro: the call is the macro called with the receiver first" {
	const result = compileToCWithStd(dotHead + `const v: string = table.twoM(1);`);
	assert result.ok, result.ok ? "" : result.error;
}

test "dot call to a macro: the arity message counts the receiver" {
	const result = compileToCWithStd(dotHead + `const v: string = table.twoM(1, 2);`);
	assert !result.ok && result.error.includes("expects 2 args, got 3"), result.ok ? "accepted" : result.error;
}

test "dot call to a macro: a same-named extension of the receiver is an ambiguity, not a pick" {
	const result = compileToCWithStd(dotHead + `function twoM(this t: Table, a: number): string { return "ext"; }\nconst v: string = table.twoM(1);`);
	assert !result.ok && result.error.includes("both a macro"), result.ok ? "accepted" : result.error;
}

test "dot call to a macro: a method of the receiver wins" {
	const result = compileToCWithStd(head + `
class Table { twoM(a: number): string { return "method"; } }
macro twoM(this src: Node, a: Node): Node { return createNodeAt(NodeKind.StringLiteral, { value: "two" }, a.location); }
const v: string = new Table().twoM(1);`);
	assert result.ok && !result.value.includes('"two"'), result.ok ? "macro ran" : result.error;
}
