import { env } from "std/process";
import { Node, NodeKind, FunctionDeclData, BinaryExprData, CallExprData, MemberExprData, IdentifierData, SourceLocation, Type } from "../ast/node";
import { FieldSink, nodeFields, nodeKindName } from "../ast/fieldspec";

export class ShareReport {
	nodes: int32 = 0;
	shared: int32 = 0;
	annotShared: int32 = 0;
	extraEdges = new HashMap<string, int32>();
}

function describe(n: Node): string {
	if (n.kind == NodeKind.CallExpr) {
		const c = (n.data as CallExprData).callee;
		return `${nodeKindName(n.kind)}(${c.kind == NodeKind.Identifier ? (c.data as IdentifierData).name : nodeKindName(c.kind)})`;
	}
	if (n.kind == NodeKind.MemberExpr) return `MemberExpr(.${(n.data as MemberExprData).property})`;
	if (n.kind == NodeKind.BinaryExpr) {
		const b = n.data as BinaryExprData;
		return `${nodeKindName(n.kind)}(${nodeKindName(b.left.kind)} ${b.operator})`;
	}
	return nodeKindName(n.kind);
}

export function countSharedNodes(root: Node): ShareReport {
	const report = new ShareReport();
	const incoming = new HashMap<Node, int32>();
	const firstParent = new HashMap<Node, string>();
	const fnOf = new HashMap<Node, string>();
	const sites = env.get("MSC_SHARE_COUNT") == "sites";
	const pending: Node[] = [root];
	incoming.set(root, 1);
	let parent = root;

	const edge = (name: string, child: Node | null): void => {
		if (child == null) return;
		const seen = incoming.get(child);
		if (seen == null) {
			incoming.set(child, 1);
			if (sites) fnOf.set(child, parent.kind == NodeKind.FunctionDecl ? (parent.data as FunctionDeclData).fnName : (fnOf.get(parent) ?? ""));
			if (sites) firstParent.set(child, `${describe(parent)}.${name}@${parent.location.line}:${parent.location.column}`);
			pending.push(child);
			return;
		}
		incoming.set(child, seen + 1);
		if (seen == 1) {
			if (name == "typeExpr" || name == "typeExprs" || name == "baseExprs") report.annotShared += 1;
			else report.shared += 1;
		}
		const at = sites ? ` @${child.location.line}:${child.location.column} also ${describe(parent)}@${parent.location.line}:${parent.location.column} first ${firstParent.get(child)} in ${fnOf.get(child)}` : "";
		const key = `${nodeKindName(parent.kind)}.${name} > ${nodeKindName(child.kind)}${at}`;
		const n = report.extraEdges.get(key);
		report.extraEdges.set(key, n == null ? 1 : n + 1);
	};
	const sink: FieldSink = {
		node: (name: string, x: Node | null): void => { edge(name, x); },
		nodes: (name: string, a: Node[] | null): void => { if (a != null) { for (const c of a) edge(name, c); } },
		nodesNested: (name: string, a: Node[][] | null): void => { if (a != null) { for (const row of a) { if (row != null) { for (const c of row) edge(name, c); } } } },
		typ: (name: string, t: Type | null): void => {},
		str: (name: string, s: string): void => {},
		strArr: (name: string, a: string[] | null): void => {},
		integer: (name: string, v: int64): void => {},
		float: (name: string, v: float64): void => {},
		bool: (name: string, b: boolean): void => {},
		loc: (name: string, l: SourceLocation | null): void => {},
		locs: (name: string, l: SourceLocation[] | null): void => {},
		floats: (name: string, a: number[] | null): void => {},
	};

	while (pending.length > 0) {
		const n = pending.pop()!;
		report.nodes += 1;
		parent = n;
		edge("typeExpr", n.typeExpr);
		if (n.typeExprs != null) { for (const c of n.typeExprs) edge("typeExprs", c); }
		if (n.baseExprs != null) { for (const c of n.baseExprs) edge("baseExprs", c); }
		nodeFields(n, sink);
	}
	return report;
}

export function reportShareIfRequested(root: Node, stage: string): void {
	if (env.get("MSC_SHARE_COUNT") == "") return;
	const r = countSharedNodes(root);
	console.error(`SHARE\t${stage}\t${r.nodes}\t${r.shared}\t${r.annotShared}`);
	if (env.get("MSC_SHARE_COUNT") != "edges" && env.get("MSC_SHARE_COUNT") != "sites") return;
	for (const [key, n] of r.extraEdges) console.error(`SHAREEDGE\t${stage}\t${key}\t${n}`);
}
