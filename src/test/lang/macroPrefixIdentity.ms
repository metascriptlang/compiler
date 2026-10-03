import { Node, NodeKind, DeclKind } from "std/meta";
import { memo, pair } from "./macroPrefixFixture";

macro eagerPrefix(): Node {
	return {
		kind: NodeKind.SpliceMany,
		line: 0,
		column: 0,
		spliceNodes: [
			{
				kind: NodeKind.ExprStmt,
				line: 0,
				column: 0,
				expr: {
					kind: NodeKind.CallExpr,
					line: 0,
					column: 0,
					callee: { kind: NodeKind.Identifier, line: 0, column: 0, name: "noteBuild" },
					arguments: [],
				},
			},
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

let notes: int32 = 0;

function noteBuild(): void { notes = notes + 1; }

function build(): string { builds = builds + 1; return "T" + builds.toString(); }

function renderEagerPrefix(): string {
	const v = eagerPrefix();
	return v;
}

test "macro prefix hoisting: effect and value execute in order once per evaluation" {
	const beforeBuilds = builds;
	const beforeNotes = notes;
	assert renderEagerPrefix() == "T" + (beforeBuilds + 1).toString();
	assert renderEagerPrefix() == "T" + (beforeBuilds + 2).toString();
	assert builds == beforeBuilds + 2;
	assert notes == beforeNotes + 2;
}

function eachRow<T>(p: { each: T[]; row: (n: T) => string }): string { return p.row(p.each[0]); }

function renderTwoSites(): string {
	return eachRow({ each: [1], row: (n) => { const x = memo(); const y = memo(); return x + y; } });
}

function injectedPairValue(): int32 { pair(); return a * 10 + b; }

test "macro prefix identity: generic recheck keeps two sites independent and persistent" {
	const before = builds;
	const expected = "T" + (before + 1).toString() + "T" + (before + 2).toString();
	assert renderTwoSites() == expected;
	assert injectedPairValue() == 12;
}
