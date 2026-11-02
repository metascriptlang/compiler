import {
	Node, NodeKind, NodeFlag, Type, TypeKind, FlowNode, FlowFlag,
	MemberExprData, ArrayAccessData, CallExprData, MoveExprData, OutExprData, BinaryExprData,
	FunctionDeclData, MethodDeclData, ConstructorDeclData, ArrowFunctionData, FunctionExprData, TestDeclData,
	HiddenStdConvData, TypeAssertionData,
} from "../ast/node";
import { forEachChild } from "../ast/visitor";
import { env } from "std/process";
import { CheckerContext } from "./context";
import { receiverOf, calledRoutineType } from "./effects";
import { isPrimitiveKind, skipModifier } from "./types";
import { carriesPointer, formalAt, calleeMayWrite } from "./varPartitions";
import { MoveScan, MoveEvent, numberNodes, reachingMove } from "./moveCheck";
import {
	Place, PlaceScope, RootKind, StepKind, Overlap, placeScope, placeOf, sourcesOf, overlap, structuralOverlap, placeText,
} from "./places";

let listing: int32 = -1;
let printed = new HashSet<string>();

function enabled(): boolean {
	if (listing < 0) listing = env.get("MSC_MOVE_PATHS_LIST") != "" ? 1 : 0;
	return listing == 1;
}

interface Unit {
	ctx: CheckerContext;
	path: string;
	scope: PlaceScope;
	body: Node;
	calls: Node[];
	moves: Node[];
}

interface Passed {
	node: Node;
	formal: Type | null;
}

export function listMovePaths(ctx: CheckerContext, root: Node | null, modulePath: string = ""): void {
	if (root == null || !enabled()) return;
	const path = modulePath != "" ? modulePath : ctx.modulePath;
	if (root.kind == NodeKind.Program) listUnit(ctx, path, null, root);
	unitsIn(ctx, path, root);
}

function bodyOf(node: Node): Node | null {
	return match (node.kind) {
		NodeKind.FunctionDecl => (node.data as FunctionDeclData).fnBody,
		NodeKind.MethodDecl => (node.data as MethodDeclData).methodBody,
		NodeKind.ConstructorDecl => (node.data as ConstructorDeclData).ctorBody,
		NodeKind.ArrowFunction => (node.data as ArrowFunctionData).arrowBody,
		NodeKind.FunctionExpr => (node.data as FunctionExprData).funcExprBody,
		NodeKind.TestDecl => (node.data as TestDeclData).testBody,
		_ => null,
	};
}

function unitsIn(ctx: CheckerContext, path: string, node: Node | null): void {
	if (node == null) return;
	const body = bodyOf(node);
	if (body != null) listUnit(ctx, path, node, body);
	forEachChild(node, (child: Node): void => { unitsIn(ctx, path, child); });
}

function nested(node: Node): boolean {
	return node.kind == NodeKind.FunctionDecl || node.kind == NodeKind.MethodDecl || node.kind == NodeKind.ConstructorDecl
		|| node.kind == NodeKind.ArrowFunction || node.kind == NodeKind.FunctionExpr || node.kind == NodeKind.TestDecl
		|| node.kind == NodeKind.ClassDecl;
}

function collect(u: Unit, node: Node): void {
	if (node.kind == NodeKind.CallExpr) u.calls.push(node);
	if (node.kind == NodeKind.MoveExpr) u.moves.push(node);
	forEachChild(node, (child: Node): void => {
		if (!nested(child)) collect(u, child);
	});
}

function listUnit(ctx: CheckerContext, path: string, routine: Node | null, body: Node): void {
	const u: Unit = { ctx, path, scope: placeScope(routine, body), body, calls: [], moves: [] };
	collect(u, body);
	for (const call of u.calls) { listCall(u, call); }
	if (u.moves.length > 0) listMoves(u);
}

function say(u: Unit, stage: string, tag: string, at: Node, text: string): void {
	const line = `move-paths ${stage} ${tag} ${u.path}:${at.location.line}:${at.location.column} ${text}`;
	if (printed.has(line)) return;
	printed.add(line);
	console.log(line);
}

function isRefFormal(t: Type | null): boolean {
	return t != null && t.kind == TypeKind.Var;
}

function byValueScalar(p: Passed): boolean {
	if (isRefFormal(p.formal)) return false;
	const t = skipModifier(p.node.nodeType);
	if (t == null) return false;
	return isPrimitiveKind(t.kind) || t.kind == TypeKind.String || t.kind == TypeKind.StringLiteral || t.kind == TypeKind.Enum
		|| t.kind == TypeKind.EnumLiteral || t.kind == TypeKind.BooleanLiteral || t.kind == TypeKind.NumberLiteral;
}

function passedOf(call: Node): Passed[] {
	const fnType = calledRoutineType(call);
	const recv = receiverOf(call);
	const out: Passed[] = [];
	let offset: int32 = 0;
	if (recv != null) {
		const ext = call.flags.has(NodeFlag.ExtCall);
		out.push({ node: recv, formal: ext ? formalAt(fnType, 0) : null });
		offset = ext ? 1 : 0;
	}
	const args = (call.data as CallExprData).arguments;
	for (let i = 0; i < args.length; i += 1) { out.push({ node: args[i], formal: formalAt(fnType, (i as int32) + offset) }); }
	return out;
}

function crossesShared(p: Place): boolean {
	if (p.rootKind == RootKind.Global) return true;
	for (const s of p.steps) {
		if (s.kind == StepKind.Deref) return true;
	}
	return false;
}

function calleeName(call: Node): string {
	const callee = (call.data as CallExprData).callee;
	if (callee == null) return "?";
	if (callee.kind == NodeKind.Identifier) return (callee.data as { name: string }).name;
	if (callee.kind == NodeKind.MemberExpr) return "." + (callee.data as MemberExprData).property;
	return "?";
}

function verdict(r: Place, a: Place): string {
	if (r.root != null && r.root == a.root) return structuralOverlap(r, a, false) != Overlap.Disjoint ? "place" : "reach";
	return "hidden";
}

function listCall(u: Unit, call: Node): void {
	const passed = passedOf(call);
	for (let ri = 0; ri < passed.length; ri += 1) {
		const r = passed[ri];
		if (!isRefFormal(r.formal)) continue;
		const rp = placeOf(u.scope, r.node);
		if (rp == null) continue;
		const ref = `${calleeName(call)} ref#${ri} ${placeText(rp)} [${rootName(rp.rootKind)}]`;
		let refused = false;
		let hidden = false;
		for (let ai = 0; ai < passed.length; ai += 1) {
			if (ai == ri) continue;
			const a = passed[ai];
			const aRef = isRefFormal(a.formal);
			const ap = placeOf(u.scope, a.node);
			if (ap != null) {
				if (overlap(rp, ap, false) == Overlap.Disjoint || byValueScalar(a)) continue;
				if (aRef && ai < ri) {
					refused = true;
					continue;
				}
				const v = verdict(rp, ap);
				const what = `${ref} vs ${ai == 0 && receiverOf(call) != null ? "receiver" : "arg"}#${ai} ${placeText(ap)}${aRef ? " (ref)" : ""}`;
				if (v == "hidden") {
					hidden = true;
					say(u, "2b", "hidden", call, what);
				} else {
					refused = true;
					say(u, "2", ai == 0 && receiverOf(call) != null && !aRef ? `receiver-${v}` : v, call, what);
				}
				continue;
			}
			const closure = a.node.kind == NodeKind.ArrowFunction || a.node.kind == NodeKind.FunctionExpr;
			if (!closure && !carriesPointer(a.node.nodeType)) continue;
			for (const s of sourcesOf(u.scope, a.node)) {
				if (overlap(rp, s, false) == Overlap.Disjoint) continue;
				const v = verdict(rp, s);
				const what = `${ref} vs computed#${ai} from ${placeText(s)}`;
				if (v == "hidden") {
					hidden = true;
					say(u, "2b", "hidden-computed", call, what);
				} else {
					refused = true;
					say(u, "2", `computed-${v}`, call, what);
				}
				break;
			}
		}
		for (let ai = ri + 1; ai < passed.length; ai += 1) {
			const change = nestedChange(u, rp, passed[ai].node);
			if (change != "") {
				refused = true;
				say(u, "2", "nested", call, `${ref} changed by arg#${ai}: ${change}`);
				break;
			}
		}
		if (!refused && !hidden && crossesShared(rp)) {
			say(u, "2b", calleeMayWrite(call) ? "rule-a" : "rule-a-filtered", call, ref);
		}
	}
}

function nestedChange(u: Unit, rp: Place, node: Node): string {
	let found = "";
	const visit = (n: Node): void => {
		if (found != "" || nested(n)) return;
		if (n.kind == NodeKind.MoveExpr || n.kind == NodeKind.OutExpr) {
			const target = n.kind == NodeKind.MoveExpr ? (n.data as MoveExprData).moveArg : (n.data as OutExprData).outArg;
			const p = placeOf(u.scope, target);
			if (p != null && structuralOverlap(rp, p, false) != Overlap.Disjoint) found = `${n.kind == NodeKind.MoveExpr ? "move" : "out"} ${placeText(p)}`;
		}
		if (found == "" && n.kind == NodeKind.CallExpr) {
			const writes = calleeMayWrite(n);
			for (const q of passedOf(n)) {
				if (!isRefFormal(q.formal) && !(writes && carriesPointer(q.node.nodeType))) continue;
				for (const s of sourcesOf(u.scope, q.node)) {
					if (structuralOverlap(rp, s, false) != Overlap.Disjoint) {
						found = `${calleeName(n)} ${isRefFormal(q.formal) ? "ref " : ""}${placeText(s)}`;
						break;
					}
				}
				if (found != "") break;
			}
			if (found == "" && writes && rp.rootKind == RootKind.Global) found = `${calleeName(n)} may write module-level ${rp.root!.name}`;
		}
		if (found == "") forEachChild(n, visit);
	};
	visit(node);
	return found;
}

interface Read {
	anchor: Node;
	place: Place;
}

interface Taken {
	move: Node;
	place: Place;
	event: MoveEvent;
}

function rootIdent(n: Node | null): Node | null {
	let at = n;
	while (at != null) {
		match (at.kind) {
			NodeKind.Identifier => { return at; },
			NodeKind.MemberExpr => { at = (at.data as MemberExprData).object; },
			NodeKind.ArrayAccess => { at = (at.data as ArrayAccessData).array; },
			NodeKind.HiddenDeref | NodeKind.HiddenAddr => { at = (at.data as { expr: Node }).expr; },
			NodeKind.HiddenStdConv | NodeKind.HiddenSubConv => { at = (at.data as HiddenStdConvData).convExpr; },
			NodeKind.TypeAssertion => { at = (at.data as TypeAssertionData).asExpr; },
			NodeKind.MoveExpr => { at = (at.data as MoveExprData).moveArg; },
			NodeKind.OutExpr => { at = (at.data as OutExprData).outArg; },
			_ => { return null; },
		};
	}
	return null;
}

function isPathNode(n: Node): boolean {
	return n.kind == NodeKind.Identifier || n.kind == NodeKind.MemberExpr || n.kind == NodeKind.ArrayAccess;
}

function lockReads(u: Unit, node: Node, writeTarget: boolean, out: Read[]): void {
	if (nested(node)) return;
	if (node.kind == NodeKind.BinaryExpr && (node.data as BinaryExprData).operator == "=") {
		const d = node.data as BinaryExprData;
		lockReads(u, d.right, false, out);
		lockReads(u, d.left, true, out);
		return;
	}
	if (node.kind == NodeKind.MoveExpr) {
		const arg = (node.data as MoveExprData).moveArg;
		const p = placeOf(u.scope, arg);
		if (p != null && p.steps.length > p.aliasSteps) {
			indexReads(u, arg, out);
			return;
		}
	}
	if (isPathNode(node)) {
		const accessor = node.kind == NodeKind.MemberExpr && node.flags.has(NodeFlag.Accessor);
		const target = accessor ? (node.data as MemberExprData).object : node;
		let p = placeOf(u.scope, target);
		if (p == null && node.kind == NodeKind.MemberExpr) p = placeOf(u.scope, (node.data as MemberExprData).object);
		const anchor = rootIdent(node);
		if (p != null && p.root != null && anchor != null && anchor.flowNode != null) {
			if (!writeTarget) out.push({ anchor, place: p });
			indexReads(u, node, out);
			return;
		}
	}
	forEachChild(node, (child: Node): void => { lockReads(u, child, false, out); });
}

function indexReads(u: Unit, node: Node, out: Read[]): void {
	let at: Node | null = node;
	while (at != null) {
		if (at.kind == NodeKind.ArrayAccess) {
			lockReads(u, (at.data as ArrayAccessData).index, false, out);
			at = (at.data as ArrayAccessData).array;
		} else if (at.kind == NodeKind.MemberExpr) {
			at = (at.data as MemberExprData).object;
		} else if (at.kind == NodeKind.HiddenDeref || at.kind == NodeKind.HiddenAddr) {
			at = (at.data as { expr: Node }).expr;
		} else if (at.kind == NodeKind.HiddenStdConv || at.kind == NodeKind.HiddenSubConv) {
			at = (at.data as HiddenStdConvData).convExpr;
		} else if (at.kind == NodeKind.TypeAssertion) {
			at = (at.data as TypeAssertionData).asExpr;
		} else {
			if (at.kind != NodeKind.Identifier) lockReads(u, at, false, out);
			return;
		}
	}
}

function refillsPlace(u: Unit, taken: Place): (flow: FlowNode) => boolean {
	return (flow: FlowNode): boolean => {
		const n = flow.node;
		if (n == null) return false;
		if (flow.flags.has(FlowFlag.Assignment)) {
			if (n.kind == NodeKind.VariableDecl) return n.resolvedSym == taken.root;
			if (n.kind != NodeKind.BinaryExpr || (n.data as BinaryExprData).operator != "=") return false;
			const p = placeOf(u.scope, (n.data as BinaryExprData).left);
			if (p == null) return false;
			const o = structuralOverlap(p, taken, false);
			return o == Overlap.Same || o == Overlap.Contains;
		}
		if (flow.flags.has(FlowFlag.Call) && n.kind == NodeKind.CallExpr) {
			for (const a of (n.data as CallExprData).arguments) {
				if (a.kind != NodeKind.OutExpr) continue;
				const p = placeOf(u.scope, a);
				if (p == null) continue;
				const o = structuralOverlap(p, taken, false);
				if (o == Overlap.Same || o == Overlap.Contains) return true;
			}
		}
		return false;
	};
}

function rootName(k: RootKind): string {
	return match (k) {
		RootKind.Local => "local",
		RootKind.OwnedParam => "owned-param",
		RootKind.SinkParam => "sink-param",
		RootKind.RefParam => "ref-param",
		RootKind.OutParam => "out-param",
		RootKind.PlainParam => "plain-param",
		RootKind.ReadonlyParam => "readonly-param",
		RootKind.Receiver => "receiver",
		RootKind.Borrowed => "borrowed",
		RootKind.ForOfElement => "for-of",
		RootKind.Global => "global",
		RootKind.Captured => "captured",
		RootKind.Temp => "temp",
	};
}

function stageOfRoot(k: RootKind): string {
	return match (k) {
		RootKind.Global | RootKind.Captured | RootKind.ForOfElement => "4",
		RootKind.PlainParam | RootKind.Receiver | RootKind.Borrowed => "7",
		RootKind.RefParam => "6",
		RootKind.Local | RootKind.OwnedParam | RootKind.SinkParam | RootKind.OutParam => "5",
		RootKind.ReadonlyParam | RootKind.Temp => "",
	};
}

function exitsOf(node: Node, out: Node[]): void {
	if (nested(node)) return;
	if (node.kind == NodeKind.ReturnStmt || node.kind == NodeKind.ThrowStmt) out.push(node);
	forEachChild(node, (child: Node): void => { exitsOf(child, out); });
}

function lastFlowIn(node: Node, scan: MoveScan): Node | null {
	let best: Node | null = null;
	let bestAt: int32 = -1;
	const visit = (n: Node): void => {
		if (nested(n)) return;
		const at = scan.order.get(n);
		if (n.flowNode != null && at != null && at > bestAt) {
			best = n;
			bestAt = at;
		}
		forEachChild(n, visit);
	};
	visit(node);
	return best;
}

function listMoves(u: Unit): void {
	const lockable: Taken[] = [];
	for (const m of u.moves) {
		const arg = (m.data as MoveExprData).moveArg;
		const p = placeOf(u.scope, arg);
		if (p == null || p.steps.length <= p.aliasSteps) continue;
		const stage = stageOfRoot(p.rootKind);
		if (stage == "") continue;
		const text = `move ${placeText(p)} [${rootName(p.rootKind)}]`;
		if (stage == "4" || stage == "7") {
			say(u, stage, "root", m, text);
			continue;
		}
		const at = rootIdent(arg);
		if (at == null || at.flowNode == null || at.resolvedSym == null) {
			say(u, stage, "no-flow", m, text);
			continue;
		}
		lockable.push({ move: m, place: p, event: { at, sym: at.resolvedSym, owner: false } });
	}
	if (lockable.length == 0) return;
	const scan = new MoveScan();
	numberNodes(u.body, scan);
	const reads: Read[] = [];
	lockReads(u, u.body, false, reads);
	const exits: Node[] = [];
	exitsOf(u.body, exits);
	for (const t of lockable) {
		const events = new HashMap<FlowNode, MoveEvent[]>();
		events.set(t.event.at.flowNode!, [t.event]);
		const clean = new HashSet<FlowNode>();
		const refills = refillsPlace(u, t.place);
		const text = `move ${placeText(t.place)} [${rootName(t.place.rootKind)}]`;
		for (const r of reads) {
			if (r.place.root != t.place.root || overlap(t.place, r.place, true) == Overlap.Disjoint) continue;
			if (reachingMove(scan, r.anchor, events, clean, refills) != null) {
				say(u, "5", "lock", t.move, `${text} read as ${placeText(r.place)} at ${r.anchor.location.line}:${r.anchor.location.column}`);
				break;
			}
		}
		if (t.place.rootKind != RootKind.RefParam) continue;
		const ends: Node[] = [];
		if (u.body.flowNode != null) ends.push(u.body);
		let unchecked = 0;
		for (const e of exits) {
			const last = lastFlowIn(e, scan);
			if (last != null) ends.push(last);
			else unchecked += 1;
		}
		const exitClean = new HashSet<FlowNode>();
		let open = false;
		for (const e of ends) {
			if (reachingMove(scan, e, events, exitClean, refills) != null) {
				say(u, "6", "exit", t.move, `${text} left moved at ${e.location.line}:${e.location.column}`);
				open = true;
				break;
			}
		}
		if (!open && unchecked > 0) say(u, "6", "exit-unchecked", t.move, `${text} (${unchecked} exits without a flow node)`);
	}
}
