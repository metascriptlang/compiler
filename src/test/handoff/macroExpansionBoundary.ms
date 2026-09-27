import { compileToCWithStd } from "../helpers";

const prefixSource = `
import { Node, NodeKind, DeclKind } from "std/meta";

macro memo(): Node {
	return {
		kind: NodeKind.SpliceMany,
		line: 0,
		column: 0,
		spliceNodes: [
			{
				kind: NodeKind.VariableDecl,
				line: 0,
				column: 0,
				declName: "cached",
				declType: "string",
				initializer: {
					kind: NodeKind.CallExpr,
					line: 0,
					column: 0,
					callee: { kind: NodeKind.Identifier, line: 0, column: 0, name: "build" },
					arguments: [],
				},
				declKind: DeclKind.Const,
				nameLocation: { line: 0, column: 0 },
			},
			{ kind: NodeKind.Identifier, line: 0, column: 0, name: "cached" },
		],
	};
}

let builds: int32 = 0;
let flag: boolean = true;
function build(): string { builds = builds + 1; return "T" + builds.toString(); }

`;

test "macro prefix hoisting: eager positions differ from conditional evaluation" {
	const cases = [
		{ expression: 'memo() !== ""', accepted: true },
		{ expression: 'flag && memo() !== ""', accepted: false },
		{ expression: 'flag || memo() !== ""', accepted: false },
		{ expression: 'flag ? memo() !== "" : false', accepted: false },
	];
	for (const item of cases) {
		const result = compileToCWithStd(prefixSource + "function check(): boolean { return " + item.expression + "; } console.log(check());");
		assert result.ok == item.accepted, item.expression;
	}
}

test "macro prefix hoisting: empty statement splices have no expression value" {
	const source = 'import { Node, NodeKind } from "std/meta"; macro empty(): Node { return { kind: NodeKind.SpliceMany, line: 0, column: 0, spliceNodes: [] }; }';
	assert compileToCWithStd(source + "empty();").ok;
	assert !compileToCWithStd(source + "const value = empty();").ok;
}

test "macro prefix hoisting: a macro can mark the decl it hoists as static storage" {
	const c = compileToCWithStd(`
import { Node, NodeKind, DeclKind, NodeFlag } from "std/meta";

macro memo(): Node {
	return {
		kind: NodeKind.SpliceMany,
		line: 0,
		column: 0,
		spliceNodes: [
			{
				kind: NodeKind.VariableDecl,
				line: 0,
				column: 0,
				flags: (0 as BitSet<NodeFlag>).incl(NodeFlag.StaticStorage),
				declName: "cached",
				declType: "string",
				initializer: {
					kind: NodeKind.CallExpr,
					line: 0,
					column: 0,
					callee: { kind: NodeKind.Identifier, line: 0, column: 0, name: "build" },
					arguments: [],
				},
				declKind: DeclKind.Const,
				nameLocation: { line: 0, column: 0 },
			},
			{ kind: NodeKind.Identifier, line: 0, column: 0, name: "cached" },
		],
	};
}

let builds: int32 = 0;
function build(): string { builds = builds + 1; return "T" + builds.toString(); }

function render(): string {
	const v = memo();
	return v;
}

function main(): void { console.log(render() + render()); }
`);
	assert c.ok;
}

test "macro storage: run-once initializers cannot capture invocation state" {
	const refused = [
`
function bump(): int32 {
	static var n = 0;
	n = n + 1;
	return n;
}
function main(): void { console.log(bump().toString()); }
`,
`
function f(n: int32): int32 {
	static const t = n + 1;
	return t;
}
function main(): void { console.log(f(1).toString()); }
`,
`
function f(): int32 {
	let k: int32 = 3;
	static const t = k + 1;
	return t;
}
function main(): void { console.log(f().toString()); }
`
	];
	for (const source of refused) assert !compileToCWithStd(source).ok, source;
	assert compileToCWithStd("function f(): int32 { static const n = 3; return n; }").ok;
}
