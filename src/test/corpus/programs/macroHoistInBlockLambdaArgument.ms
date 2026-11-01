// @stdout: T1 T1|S1 T2 T2|T3 T3
// @exit: 0
// note: a macro call that hoists a static, written inside a block-bodied lambda that is the argument of another macro, keeps its hoist: the outer macro is the identity wrapper, the outer macro carries a static of its own, and the lambda sits one more macro deeper. Each static is built once, so a second call reads the same value.

import { Node, NodeKind, DeclKind, NodeFlag } from "std/meta";

let builds: int32 = 0;
function build(): string {
	builds = builds + 1;
	return "T" + builds.toString();
}

let outerBuilds: int32 = 0;
function buildOuter(): string {
	outerBuilds = outerBuilds + 1;
	return "S" + outerBuilds.toString();
}

function use(f: () => string): string {
	return f();
}

function useTagged(tag: string, f: () => string): string {
	return tag + " " + f();
}

macro memo(): Node {
	return {
		kind: NodeKind.SpliceMany, line: 0, column: 0,
		spliceNodes: [
			{
				kind: NodeKind.VariableDecl, line: 0, column: 0,
				flags: (0 as BitSet<NodeFlag>).incl(NodeFlag.StaticStorage),
				declName: "tpl", declType: "string",
				initializer: {
					kind: NodeKind.CallExpr, line: 0, column: 0,
					callee: { kind: NodeKind.Identifier, line: 0, column: 0, name: "build" },
					arguments: [],
				},
				declKind: DeclKind.Const, nameLocation: { line: 0, column: 0 },
			},
			{ kind: NodeKind.Identifier, line: 0, column: 0, name: "tpl" },
		],
	};
}

macro wrap(inner: Node): Node {
	return {
		kind: NodeKind.CallExpr, line: 0, column: 0,
		callee: { kind: NodeKind.Identifier, line: 0, column: 0, name: "use" },
		arguments: [inner],
	};
}

macro wrapTagged(inner: Node): Node {
	return {
		kind: NodeKind.SpliceMany, line: 0, column: 0,
		spliceNodes: [
			{
				kind: NodeKind.VariableDecl, line: 0, column: 0,
				flags: (0 as BitSet<NodeFlag>).incl(NodeFlag.StaticStorage),
				declName: "tag", declType: "string",
				initializer: {
					kind: NodeKind.CallExpr, line: 0, column: 0,
					callee: { kind: NodeKind.Identifier, line: 0, column: 0, name: "buildOuter" },
					arguments: [],
				},
				declKind: DeclKind.Const, nameLocation: { line: 0, column: 0 },
			},
			{
				kind: NodeKind.CallExpr, line: 0, column: 0,
				callee: { kind: NodeKind.Identifier, line: 0, column: 0, name: "useTagged" },
				arguments: [{ kind: NodeKind.Identifier, line: 0, column: 0, name: "tag" }, inner],
			},
		],
	};
}

function viaBlock(): string {
	return wrap((): string => { return memo(); });
}

function viaTagged(): string {
	return wrapTagged((): string => { return memo(); });
}

function viaDeeper(): string {
	return wrap((): string => { return wrap((): string => { return memo(); }); });
}

const first = `${viaBlock()} ${viaBlock()}`;
const tagged = viaTagged();
const again = viaTagged();
const deeper = `${viaDeeper()} ${viaDeeper()}`;
console.log(`${first}|${tagged} ${again.substring(3)}|${deeper}`);
