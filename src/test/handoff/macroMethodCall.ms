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
