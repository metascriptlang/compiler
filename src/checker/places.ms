import {
	Node, NodeKind, NodeFlag, Symbol, SymbolKind, Type, TypeKind,
	MemberExprData, ArrayAccessData, TypeAssertionData, HiddenStdConvData, MoveExprData, OutExprData,
	CallExprData, ConditionalExprData, ArrayLiteralData, ObjectLiteralData, NewExprData, VariableDeclData,
	DestructuringDeclData, ObjectPatternData, ObjectPatternPropData, ArrayPatternData, NumberLiteralData,
	BinaryExprData, SpreadExprData, FunctionDeclData, ProgramData,
} from "../ast/node";
import { forEachChild } from "../ast/visitor";
import { receiverOf, routineBody } from "./effects";
import { hasFlag, SymbolFlag } from "./symbol";
import { isOwnedRef, isReadonlyView, isViewType, isOutParam, TypeVisitSet, typeVisitAdd, skipModifier } from "./types";
import { sameUpToDistinct } from "./checkExprPass";
import { carriesPointer, pathOf } from "./varPartitions";
import { isAddressTaking } from "./pointerAddress";
import { parseSource } from "../parser/statements/validation";
import { checkProgram } from "./checkPass";

export enum StepKind {
	Field,
	Index,
	Slice,
	Variant,
	Deref,
}

export enum IndexKind {
	Constant,
	Local,
	Unknown,
}

export interface PlaceStep {
	kind: StepKind;
	field: string;
	index: IndexKind;
	constant: int64;
	indexSym: Symbol | null;
	checked: boolean;
	inUnion: boolean;
	type: Type | null;
}

export enum RootKind {
	Local,
	OwnedParam,
	SinkParam,
	RefParam,
	OutParam,
	PlainParam,
	ReadonlyParam,
	Receiver,
	Borrowed,
	ForOfElement,
	Global,
	Captured,
	Temp,
}

export interface Place {
	root: Symbol | null;
	rootKind: RootKind;
	steps: PlaceStep[];
	aliasSteps: int32;
	written: Node;
}

export enum Overlap {
	Disjoint,
	Same,
	Inside,
	Contains,
	Maybe,
}

export interface PlaceScope {
	routine: Node | null;
	nodes: HashSet<Node>;
	lets: HashMap<Symbol, Node[]>;
	resolving: Symbol[];
}

export function placeScope(routine: Node | null, body: Node | null): PlaceScope {
	const scope: PlaceScope = { routine, nodes: new HashSet<Node>(), lets: new HashMap<Symbol, Node[]>(), resolving: [] };
	if (routine != null) scope.nodes.add(routine);
	collectScope(scope, body);
	return scope;
}

function collectScope(scope: PlaceScope, node: Node | null): void {
	if (node == null) return;
	scope.nodes.add(node);
	if (node.kind == NodeKind.BinaryExpr) {
		const d = node.data as BinaryExprData;
		const left = peel(d.left);
		if (d.operator == "=" && left != null && left.kind == NodeKind.Identifier && left.resolvedSym != null) {
			const known = scope.lets.get(left.resolvedSym);
			if (known != null) {
				known.push(d.right);
			} else {
				scope.lets.set(left.resolvedSym, [d.right]);
			}
		}
	}
	forEachChild(node, (child: Node): void => { collectScope(scope, child); });
}

function peel(n: Node | null): Node | null {
	let at = n;
	while (at != null) {
		match (at.kind) {
			NodeKind.HiddenDeref | NodeKind.HiddenAddr => { at = (at.data as { expr: Node }).expr; },
			NodeKind.HiddenStdConv | NodeKind.HiddenSubConv => { at = (at.data as HiddenStdConvData).convExpr; },
			_ => { return at; },
		};
	}
	return at;
}

function withoutNull(t: Type): Type {
	if (t.kind != TypeKind.Union) return t;
	let only: Type | null = null;
	for (const m of t.typeChildren) {
		if (m.kind == TypeKind.Null) continue;
		if (only != null) return t;
		only = m;
	}
	return only != null ? only : t;
}

function held(t: Type | null): Type | null {
	let at = skipModifier(t);
	while (at != null && (at.kind == TypeKind.Distinct || (at.kind == TypeKind.GenericInstance && at.typeReturn != null))) at = skipModifier(at.typeReturn);
	return at != null ? withoutNull(at) : null;
}

function pointeeOf(t: Type | null): Type | null {
	const h = held(t);
	if (h == null) return null;
	return match (h.kind) {
		TypeKind.Ref | TypeKind.Ptr | TypeKind.Borrow => h.typeReturn != null ? h.typeReturn : h,
		TypeKind.Span | TypeKind.GenericParam | TypeKind.Unknown => h,
		_ => null,
	};
}

export function holdsReference(t: Type | null): boolean {
	return pointeeOf(t) != null;
}

function step(kind: StepKind, type: Type | null): PlaceStep {
	return { kind, field: "", index: IndexKind.Unknown, constant: 0, indexSym: null, checked: false, inUnion: false, type };
}

function derefIfReference(steps: PlaceStep[], holder: Node): void {
	const h = peel(holder);
	const pointee = h != null ? pointeeOf(h.nodeType) : null;
	if (pointee != null) steps.push(step(StepKind.Deref, pointee));
}

function isLengthRead(n: Node): boolean {
	const d = n.data as MemberExprData;
	if (d.property != "length" && d.property != "byteLength") return false;
	const h = held(d.object.nodeType);
	return h != null && (h.kind == TypeKind.Array || h.kind == TypeKind.String || h.kind == TypeKind.SizedArray || h.kind == TypeKind.Span
		|| (h.kind == TypeKind.Ref && h.typeReturn != null && h.typeReturn.kind == TypeKind.Array));
}

function inUnionHolder(holder: Node): boolean {
	const at = peel(holder);
	let h = at != null ? held(at.nodeType) : null;
	if (h != null && (h.kind == TypeKind.Ref || h.kind == TypeKind.Ptr) && h.typeReturn != null) h = withoutNull(h.typeReturn);
	return h != null && h.kind == TypeKind.Union;
}

function indexStep(n: Node): PlaceStep {
	const d = n.data as ArrayAccessData;
	if (isViewType(n.nodeType)) return step(StepKind.Slice, n.nodeType);
	const s = step(StepKind.Index, n.nodeType);
	const i = peel(d.index);
	if (i != null && i.kind == NodeKind.NumberLiteral && !(i.data as NumberLiteralData).isFloat) {
		s.index = IndexKind.Constant;
		s.constant = (i.data as NumberLiteralData).intVal;
	} else if (i != null && i.kind == NodeKind.Identifier && i.resolvedSym != null
		&& (i.resolvedSym.symbolKind == SymbolKind.Variable || i.resolvedSym.symbolKind == SymbolKind.Parameter)) {
		s.index = IndexKind.Local;
		s.indexSym = i.resolvedSym;
	}
	return s;
}

export function placeOf(scope: PlaceScope, n: Node | null): Place | null {
	if (n == null) return null;
	const steps: PlaceStep[] = [];
	let at: Node = n;
	while (true) {
		match (at.kind) {
			NodeKind.Identifier => {
				steps.reverse();
				return rootPlace(scope, at, steps, n);
			},
			NodeKind.MemberExpr => {
				const d = at.data as MemberExprData;
				if (steps.length == 0 && isLengthRead(at)) return null;
				const s = step(StepKind.Field, at.nodeType);
				s.field = d.property;
				s.inUnion = inUnionHolder(d.object);
				steps.push(s);
				derefIfReference(steps, d.object);
				at = d.object;
			},
			NodeKind.ArrayAccess => {
				const d = at.data as ArrayAccessData;
				steps.push(indexStep(at));
				derefIfReference(steps, d.array);
				at = d.array;
			},
			NodeKind.HiddenDeref | NodeKind.HiddenAddr => { at = (at.data as { expr: Node }).expr; },
			NodeKind.HiddenStdConv | NodeKind.HiddenSubConv => { at = (at.data as HiddenStdConvData).convExpr; },
			NodeKind.MoveExpr => { at = (at.data as MoveExprData).moveArg; },
			NodeKind.OutExpr => { at = (at.data as OutExprData).outArg; },
			NodeKind.TypeAssertion => {
				if (!isAddressTaking(at)) {
					const s = step(StepKind.Variant, at.nodeType);
					s.field = (at.data as TypeAssertionData).asType;
					s.checked = at.flags.has(NodeFlag.ObjCheck) || at.flags.has(NodeFlag.ConvCheck);
					steps.push(s);
				}
				at = (at.data as TypeAssertionData).asExpr;
			},
			_ => {
				if (steps.length == 0) return null;
				steps.reverse();
				return { root: null, rootKind: RootKind.Temp, steps, aliasSteps: 0, written: n };
			},
		};
	}
	throw new Error("internal: placeOf left its walk without a root");
}

function rootPlace(scope: PlaceScope, ident: Node, steps: PlaceStep[], written: Node): Place {
	const sym = ident.resolvedSym;
	if (sym == null) return { root: null, rootKind: RootKind.Temp, steps, aliasSteps: 0, written };
	const kind = rootKindOf(scope, sym);
	const own: Place = { root: sym, rootKind: kind, steps, aliasSteps: 0, written };
	if (kind != RootKind.Local || scope.resolving.includes(sym)) return own;
	scope.resolving.push(sym);
	const out = canonical(scope, sym, own);
	scope.resolving.pop();
	return out;
}

function canonical(scope: PlaceScope, sym: Symbol, own: Place): Place {
	if (hasFlag(sym, SymbolFlag.Mutable)) {
		const values: Node[] = [];
		const init = initializerOf(sym);
		if (init != null) values.push(init);
		const later = scope.lets.get(sym);
		if (later != null) {
			for (const v of later) { values.push(v); }
		}
		let kind = RootKind.Local;
		for (const v of values) { kind = stricter(kind, valueKind(scope, sym, v)); }
		own.rootKind = kind;
		return own;
	}
	const decl = sym.declNode;
	if (decl != null && decl.kind == NodeKind.DestructuringDecl) {
		const d = decl.data as DestructuringDeclData;
		const inner: PlaceStep[] = [];
		if (!patternPath(d.destrPattern, sym, d.destrInit.nodeType, inner)) return own;
		return rebased(scope, sym, d.destrInit, inner, own);
	}
	const init = initializerOf(sym);
	if (init == null) return own;
	return rebased(scope, sym, init, [], own);
}

function rebased(scope: PlaceScope, sym: Symbol, init: Node, inner: PlaceStep[], own: Place): Place {
	const value = peel(init);
	const base = holdsReference(sym.symbolType) && value != null && value.kind != NodeKind.MoveExpr ? placeOf(scope, init) : null;
	if (base == null || base.root == null) {
		own.rootKind = valueKind(scope, sym, init);
		return own;
	}
	const steps: PlaceStep[] = [];
	for (const s of base.steps) { steps.push(s); }
	for (const s of inner) { steps.push(s); }
	const aliasSteps = steps.length as int32;
	for (const s of own.steps) { steps.push(s); }
	return { root: base.root, rootKind: base.rootKind, steps, aliasSteps, written: own.written };
}

function initializerOf(sym: Symbol): Node | null {
	const decl = sym.declNode;
	if (decl == null || decl.kind != NodeKind.VariableDecl) return null;
	return (decl.data as VariableDeclData).initializer;
}

function patternPath(pattern: Node | null, sym: Symbol, holder: Type | null, out: PlaceStep[]): boolean {
	const p = peel(pattern);
	if (p == null) return false;
	if (p.kind == NodeKind.Identifier) return p.resolvedSym == sym;
	const pointee = pointeeOf(holder);
	const at = out.length;
	if (pointee != null) out.push(step(StepKind.Deref, pointee));
	if (p.kind == NodeKind.ObjectPattern) {
		for (const prop of (p.data as ObjectPatternData).patternProps) {
			if (prop.kind != NodeKind.ObjectPatternProp) continue;
			const d = prop.data as ObjectPatternPropData;
			const s = step(StepKind.Field, d.propAlias.nodeType);
			s.field = d.propKey;
			out.push(s);
			if (patternPath(d.propAlias, sym, d.propAlias.nodeType, out)) return true;
			out.pop();
		}
	} else if (p.kind == NodeKind.ArrayPattern) {
		const elements = (p.data as ArrayPatternData).patternElements;
		for (let i = 0; i < elements.length; i += 1) {
			const s = step(StepKind.Index, elements[i].nodeType);
			s.index = IndexKind.Constant;
			s.constant = i as int64;
			out.push(s);
			if (patternPath(elements[i], sym, elements[i].nodeType, out)) return true;
			out.pop();
		}
	}
	while (out.length > at) out.pop();
	return false;
}

function valueKind(scope: PlaceScope, sym: Symbol, value: Node): RootKind {
	const v = peel(value);
	if (v == null) return RootKind.Local;
	if (v.kind == NodeKind.Identifier && v.resolvedSym == sym) return RootKind.Local;
	const p = placeOf(scope, v);
	if (p != null && p.root != null) return holdsReference(sym.symbolType) ? p.rootKind : RootKind.Local;
	if (!holdsReference(v.nodeType) || isOwnedRef(held(v.nodeType))) return RootKind.Local;
	return match (v.kind) {
		NodeKind.NewExpr | NodeKind.ObjectLiteral | NodeKind.ArrayLiteral | NodeKind.MoveExpr | NodeKind.NullLiteral
			| NodeKind.ArrowFunction | NodeKind.FunctionExpr => RootKind.Local,
		_ => RootKind.Borrowed,
	};
}

function stricter(a: RootKind, b: RootKind): RootKind {
	return severity(b) > severity(a) ? b : a;
}

function severity(k: RootKind): int32 {
	return match (k) {
		RootKind.Local | RootKind.OwnedParam | RootKind.SinkParam | RootKind.OutParam | RootKind.Temp => 0,
		RootKind.RefParam => 1,
		RootKind.Borrowed => 2,
		RootKind.PlainParam => 3,
		RootKind.Receiver => 4,
		RootKind.ReadonlyParam => 5,
		RootKind.ForOfElement => 6,
		RootKind.Captured => 7,
		RootKind.Global => 8,
	};
}

export function rootKindOf(scope: PlaceScope, sym: Symbol): RootKind {
	if (hasFlag(sym, SymbolFlag.Global) || hasFlag(sym, SymbolFlag.StaticLocal) || hasFlag(sym, SymbolFlag.Static) || sym.staticOwner != null) return RootKind.Global;
	if (sym.symbolKind != SymbolKind.Variable && sym.symbolKind != SymbolKind.Parameter) return RootKind.Global;
	if (sym.name == "this") return RootKind.Receiver;
	if (sym.symbolKind == SymbolKind.Parameter) {
		const routine = scope.routine;
		if (routine != null && routine.paramSyms != null && !routine.paramSyms.includes(sym)) return RootKind.Captured;
		return paramKind(sym);
	}
	if (hasFlag(sym, SymbolFlag.ForVar) && (sym.declNode == null || sym.declNode.kind != NodeKind.ForInStmt)) return RootKind.ForOfElement;
	if (scope.routine != null && (sym.declNode == null || !scope.nodes.has(sym.declNode))) return RootKind.Captured;
	return RootKind.Local;
}

function paramKind(sym: Symbol): RootKind {
	const t = sym.symbolType;
	if (t != null && t.kind == TypeKind.Var) return isOutParam(t) ? RootKind.OutParam : RootKind.RefParam;
	if (hasFlag(sym, SymbolFlag.Sink) || (t != null && t.kind == TypeKind.Sink)) return RootKind.SinkParam;
	if (t != null && (isOwnedRef(t) || isOwnedRef(held(t)))) return RootKind.OwnedParam;
	if (isReadonlyView(t)) return RootKind.ReadonlyParam;
	return RootKind.PlainParam;
}

export function sourcesOf(scope: PlaceScope, n: Node | null): Place[] {
	const out: Place[] = [];
	addSources(scope, n, out);
	return out;
}

function addSources(scope: PlaceScope, node: Node | null, out: Place[]): void {
	const n = peel(node);
	if (n == null) return;
	const p = placeOf(scope, n);
	if (p != null) {
		out.push(p);
		return;
	}
	match (n.kind) {
		NodeKind.MoveExpr => addSources(scope, (n.data as MoveExprData).moveArg, out),
		NodeKind.TypeAssertion => addSources(scope, (n.data as TypeAssertionData).asExpr, out),
		NodeKind.ConditionalExpr => {
			const d = n.data as ConditionalExprData;
			addSources(scope, d.ternaryConsequent, out);
			addSources(scope, d.ternaryAlternate, out);
		},
		NodeKind.ArrayLiteral => { for (const e of (n.data as ArrayLiteralData).elements) { if (carriesPointer(e.nodeType)) addSources(scope, e, out); } },
		NodeKind.ObjectLiteral => { for (const e of (n.data as ObjectLiteralData).properties) { if (carriesPointer(e.nodeType)) addSources(scope, e, out); } },
		NodeKind.SpreadExpr => addSources(scope, (n.data as SpreadExprData).spreadArg, out),
		NodeKind.NewExpr => {
			if (!carriesPointer(n.nodeType)) return;
			for (const a of (n.data as NewExprData).newArguments) { if (carriesPointer(a.nodeType)) addSources(scope, a, out); }
		},
		NodeKind.CallExpr => {
			if (!carriesPointer(n.nodeType)) return;
			const recv = receiverOf(n);
			if (recv != null && carriesPointer(recv.nodeType)) addSources(scope, recv, out);
			for (const a of (n.data as CallExprData).arguments) { if (carriesPointer(a.nodeType)) addSources(scope, a, out); }
		},
		NodeKind.ArrowFunction | NodeKind.FunctionExpr => {
			const inner = placeScope(n, routineBody(n));
			addCaptures(scope, inner, routineBody(n), out);
		},
		_ => {},
	};
}

function addCaptures(outer: PlaceScope, inner: PlaceScope, node: Node | null, out: Place[]): void {
	if (node == null) return;
	if (node.kind == NodeKind.Identifier && node.resolvedSym != null) {
		const sym = node.resolvedSym;
		const kind = rootKindOf(inner, sym);
		if ((kind == RootKind.Captured || kind == RootKind.Receiver) && !out.some((p: Place): boolean => p.root == sym && p.steps.length == 0)) {
			const p = placeOf(outer, node);
			if (p != null) {
				p.steps = p.steps.slice(0, p.aliasSteps);
				out.push(p);
			}
		}
		return;
	}
	forEachChild(node, (child: Node): void => { addCaptures(outer, inner, child, out); });
}

function sameType(a: Type, b: Type): boolean {
	if (a == b) return true;
	if (a.kind != b.kind) return false;
	if (a.kind == TypeKind.Struct && a.sym != null) return a.sym == b.sym;
	return sameUpToDistinct(a, b);
}

function opaque(t: Type): boolean {
	return t.kind == TypeKind.GenericParam || t.kind == TypeKind.Unknown || t.kind == TypeKind.TypeReference || t.kind == TypeKind.Pending;
}

let reachMemo = new HashMap<Type, Type[]>();

function reachableFrom(t: Type): Type[] {
	const known = reachMemo.get(t);
	if (known != null) return known;
	const out: Type[] = [];
	const seen = new TypeVisitSet();
	const todo: Type[] = [t];
	while (todo.length > 0) {
		const at = todo.pop();
		if (!typeVisitAdd(seen, at)) continue;
		out.push(at);
		if (at.typeReturn != null) todo.push(at.typeReturn);
		for (const c of at.typeChildren) {
			if (c != null) todo.push(c);
		}
	}
	reachMemo.set(t, out);
	return out;
}

export function reachesType(from: Type | null, target: Type | null): boolean {
	if (from == null || target == null || opaque(target)) return true;
	for (const t of reachableFrom(from)) {
		if (opaque(t) || sameType(t, target)) return true;
	}
	return false;
}

function rootType(p: Place): Type | null {
	return p.root != null ? p.root.symbolType : p.written.nodeType;
}

function sideType(p: Place, at: int32): Type | null {
	return at < 0 ? rootType(p) : p.steps[at].type;
}

function derefReached(a: Place, from: Type | null, after: int32): boolean {
	for (let k = after + 1; k < a.steps.length; k += 1) {
		if (a.steps[k].kind == StepKind.Deref && reachesType(from, a.steps[k].type)) return true;
	}
	return false;
}

function valueReaches(a: Place, b: Place): boolean {
	const value = b.written.nodeType;
	return value != null && carriesPointer(value) && derefReached(a, value, -1);
}

function reachOverlap(a: Place, b: Place, diverged: int32): boolean {
	if (valueReaches(a, b) || valueReaches(b, a)) return true;
	return derefReached(a, sideType(b, diverged), diverged) && derefReached(b, sideType(a, diverged), diverged);
}

function sameIndex(a: PlaceStep, b: PlaceStep): boolean {
	if (a.index == IndexKind.Constant && b.index == IndexKind.Constant) return a.constant == b.constant;
	return a.index == IndexKind.Local && b.index == IndexKind.Local && a.indexSym == b.indexSym;
}

export function overlap(a: Place, b: Place, lockBias: boolean): Overlap {
	return overlapIn(a, b, lockBias, !lockBias);
}

export function structuralOverlap(a: Place, b: Place, lockBias: boolean): Overlap {
	return overlapIn(a, b, lockBias, false);
}

function overlapIn(a: Place, b: Place, lockBias: boolean, reach: boolean): Overlap {
	if (a.root == null || a.root != b.root) return reach && reachOverlap(a, b, -1) ? Overlap.Maybe : Overlap.Disjoint;
	let maybe = false;
	const common = a.steps.length < b.steps.length ? a.steps.length : b.steps.length;
	for (let i = 0; i < common; i += 1) {
		const sa = a.steps[i];
		const sb = b.steps[i];
		if (sa.kind != sb.kind) return Overlap.Maybe;
		match (sa.kind) {
			StepKind.Deref => {},
			StepKind.Field => {
				if (sa.field != sb.field) {
					if (sa.inUnion || sb.inUnion) return Overlap.Maybe;
					return reach && reachOverlap(a, b, i) ? Overlap.Maybe : Overlap.Disjoint;
				}
			},
			StepKind.Variant => {
				if (sa.field != sb.field) {
					if (!sa.checked || !sb.checked) return Overlap.Maybe;
					return reach && reachOverlap(a, b, i) ? Overlap.Maybe : Overlap.Disjoint;
				}
			},
			StepKind.Index => {
				if (lockBias) return Overlap.Maybe;
				if (!sameIndex(sa, sb)) maybe = true;
			},
			StepKind.Slice => {
				if (lockBias) return Overlap.Maybe;
				maybe = true;
			},
		};
	}
	if (maybe) return Overlap.Maybe;
	if (a.steps.length == b.steps.length) return Overlap.Same;
	return a.steps.length < b.steps.length ? Overlap.Contains : Overlap.Inside;
}

export function varPath(p: Place): string {
	if (p.root == null) return "";
	let out = "";
	for (let i = p.aliasSteps; i < p.steps.length; i += 1) {
		const s = p.steps[i];
		if (s.kind == StepKind.Field) out = out + "." + s.field;
		else if (s.kind == StepKind.Index) out = out + "[]";
	}
	return out;
}

export function placeText(p: Place): string {
	let out = p.root != null ? p.root.name : "<temp>";
	for (const s of p.steps) {
		out = out + match (s.kind) {
			StepKind.Field => "." + s.field,
			StepKind.Index => s.index == IndexKind.Constant ? `[${s.constant}]` : s.index == IndexKind.Local ? `[${s.indexSym!.name}]` : "[?]",
			StepKind.Slice => "[..]",
			StepKind.Variant => ` as ${s.field}`,
			StepKind.Deref => "*",
		};
	}
	return out;
}

function probeBody(source: string): Node {
	const pr = parseSource(source);
	if (!pr.ok) throw new Error(`probe source does not parse: ${pr.error}`);
	const ctx = checkProgram(pr.value);
	for (const e of ctx.errors) { throw new Error(`probe source does not check: ${e.line}:${e.column} ${e.message}`); }
	const program = pr.value.data as ProgramData;
	for (const s of program.programStmts) {
		if (s.kind == NodeKind.FunctionDecl && (s.data as FunctionDeclData).fnName == "probe") return s;
	}
	throw new Error("probe source has no function 'probe'");
}

function pairsIn(node: Node | null, out: Node[]): void {
	if (node == null) return;
	if (node.kind == NodeKind.CallExpr) {
		const callee = peel((node.data as CallExprData).callee);
		if (callee != null && callee.kind == NodeKind.Identifier && (callee.data as { name: string }).name == "pair") out.push(node);
	}
	forEachChild(node, (child: Node): void => { pairsIn(child, out); });
}

function sourceOverlap(scope: PlaceScope, a: Node, b: Node, lockBias: boolean): Overlap {
	const pa = placeOf(scope, a);
	const pb = placeOf(scope, b);
	if (pa != null && pb != null) return overlap(pa, pb, lockBias);
	let worst = Overlap.Disjoint;
	for (const x of pa != null ? [pa] : sourcesOf(scope, a)) {
		for (const y of pb != null ? [pb] : sourcesOf(scope, b)) {
			const o = overlap(x, y, lockBias);
			if (worst == Overlap.Disjoint) worst = o;
		}
	}
	return worst;
}

function sameList<T>(a: T[], b: T[]): boolean {
	if (a.length != b.length) return false;
	for (let i = 0; i < a.length; i += 1) {
		if (a[i] != b[i]) return false;
	}
	return true;
}

function answers(source: string, lockBias: boolean = false): Overlap[] {
	const routine = probeBody("function pair<A, B>(a: A, b: B): void {}\n" + source);
	const scope = placeScope(routine, routineBody(routine));
	const calls: Node[] = [];
	pairsIn(routineBody(routine), calls);
	const out: Overlap[] = [];
	for (const c of calls) {
		const args = (c.data as CallExprData).arguments;
		out.push(sourceOverlap(scope, args[0], args[1], lockBias));
	}
	return out;
}

function rootKinds(source: string): RootKind[] {
	const routine = probeBody(source);
	const scope = placeScope(routine, routineBody(routine));
	const calls: Node[] = [];
	pairsIn(routineBody(routine), calls);
	const out: RootKind[] = [];
	for (const c of calls) {
		const p = placeOf(scope, (c.data as CallExprData).arguments[0]);
		out.push(p != null ? p.rootKind : RootKind.Temp);
	}
	return out;
}

test "places: the reference's alias table over owned locals, as overlap answers" {
	const got = answers("struct S { f: int32; v: int32; }\nfunction probe(): void {\n\tconst x: S = { f: 1, v: 2 };\n\tconst xs: Vec<int32> = [1, 2];\n\tconst i: int32 = 0;\n\tconst j: int32 = 1;\n"
		+ "\tpair(x, x); pair(x, x.f); pair(x.f, x); pair(x.f, x.f); pair(x.f, x.v);\n"
		+ "\tpair(xs, xs[0]); pair(xs[0], xs); pair(xs[0], xs[0]); pair(xs[0], xs[1]);\n"
		+ "\tpair(xs, xs[i]); pair(xs[i], xs); pair(xs[i], xs[i]); pair(xs[i], xs[j]); pair(xs[0], xs[i]);\n}\n");
	assert sameList(got, [
		Overlap.Same, Overlap.Contains, Overlap.Inside, Overlap.Same, Overlap.Disjoint,
		Overlap.Contains, Overlap.Inside, Overlap.Same, Overlap.Maybe,
		Overlap.Contains, Overlap.Inside, Overlap.Same, Overlap.Maybe, Overlap.Maybe,
	]), `${got}`;
}

test "places: projections follow the borrow checker's conflict walk" {
	const got = answers("class N { key: int32 = 7; left: Owned<N> | null = null; right: Owned<N> | null = null; }\nstruct P { a: int32; b: N | null; }\n"
		+ "function probe(n: N, m: N, xs: int32[]): void {\n\tconst p: P = { a: 1, b: null };\n\tconst q: P = { a: 1, b: null };\n\tconst v: Vec<int32> = [1, 2, 3];\n"
		+ "\tpair(p.a, q.a); pair(p.a, p.b); pair(n.key, n.left); pair(n.left, n.right); pair(n.key, m.key); pair(xs[0], v[0]);\n"
		+ "\tpair(v.length, v[0]);\n}\n");
	assert sameList(got, [Overlap.Disjoint, Overlap.Disjoint, Overlap.Maybe, Overlap.Maybe, Overlap.Maybe, Overlap.Disjoint, Overlap.Disjoint]), `${got}`;
}

test "places: the lock makes every element of a container overlap" {
	const got = answers("struct E { f: int32; g: int32; }\nfunction probe(): void {\n\tconst xs: Vec<E> = [{ f: 1, g: 2 }];\n\tconst i: int32 = 0;\n\tconst j: int32 = 0;\n"
		+ "\tpair(xs[i].f, xs[i].g); pair(xs[i].f, xs[j].g); pair(xs[i].f, xs[i].f);\n}\n", true);
	assert sameList(got, [Overlap.Maybe, Overlap.Maybe, Overlap.Maybe]), `${got}`;
	const free = answers("struct E { f: int32; g: int32; }\nfunction probe(): void {\n\tconst xs: Vec<E> = [{ f: 1, g: 2 }];\n\tconst i: int32 = 0;\n\tconst j: int32 = 0;\n"
		+ "\tpair(xs[i].f, xs[i].g); pair(xs[i].f, xs[j].g);\n}\n");
	assert sameList(free, [Overlap.Disjoint, Overlap.Disjoint]), `${free}`;
	const siblings = answers("class N { key: int32 = 7; left: N | null = null; self: N | null = null; }\nfunction probe(): void {\n\tconst t = new N();\n"
		+ "\tpair(t.left, t.self); pair(t.left, t.key); pair(t.left, t);\n}\n", true);
	assert sameList(siblings, [Overlap.Disjoint, Overlap.Disjoint, Overlap.Inside]), `${siblings}`;
}

test "places: the review's exclusivity shapes x1 to x5 and f12b overlap" {
	const shapes = "class N { key: int32 = 7; left: N | null = null; self: N | null = null; }\nfunction id(n: N): N { return n; }\n";
	const got = answers(shapes + "function probe(c: boolean, u: N): void {\n\tconst t = new N();\n"
		+ "\tpair(t.left, id(t)); pair(t.left, c ? t : u); pair(t.left, (): void => { t.left = null; }); pair(t, t.left); pair(t.left, t.self);\n}\n");
	assert sameList(got, [Overlap.Inside, Overlap.Inside, Overlap.Inside, Overlap.Contains, Overlap.Maybe]), `${got}`;
	const hidden = answers("class C { v: int32 = 1; }\nclass P { child: Owned<C> = new C(); }\nfunction probe(a: P, b: P): void {\n\tpair(a.child.v, b); pair(a.child.v, b.child.v);\n}\n");
	assert sameList(hidden, [Overlap.Maybe, Overlap.Maybe]), `${hidden}`;
}

test "places: a local that only names a place takes that place's root" {
	const kinds = rootKinds("function pair<A, B>(a: A, b: B): void {}\nclass N { key: int32 = 7; next: N | null = null; data: Owned<N> | null = null; }\nfunction first(n: N): N { return n; }\nlet G: N = new N();\n"
		+ "function probe(node: N, sink s: N, own: Owned<N>, ref r: N, xs: N[]): void {\n"
		+ "\tconst d = node.next!;\n\tconst o = own.data!;\n\tconst k = first(node);\n\tconst f = new N();\n\tconst { next: n2 } = node;\n\tlet m = new N();\n\tm = node;\n"
		+ "\tpair(d.key, 0); pair(o.key, 0); pair(k.key, 0); pair(f.key, 0); pair(n2!.key, 0); pair(m.key, 0); pair(s.key, 0); pair(r.key, 0); pair(G.key, 0);\n"
		+ "\tfor (const e of xs) pair(e.key, 0);\n\tconst run = (): int32 => { pair(node.key, 0); return 0; };\n}\n");
	assert sameList(kinds, [
		RootKind.PlainParam, RootKind.OwnedParam, RootKind.Borrowed, RootKind.Local, RootKind.PlainParam, RootKind.PlainParam,
		RootKind.SinkParam, RootKind.RefParam, RootKind.Global, RootKind.ForOfElement, RootKind.PlainParam,
	]), `${kinds}`;
}

test "places: varPath gives the string the partitions build today" {
	const routine = probeBody("class N { key: int32 = 7; kids: Vec<N> = []; }\nstruct S { n: N; xs: int32[]; }\nfunction pair<A, B>(a: A, b: B): void {}\n"
		+ "function probe(s: S, node: N, i: int32): void {\n\tpair(s.n.kids[i].key, s.xs[0]); pair(node, node.kids[0]); pair((node as N).key, node.kids[i]);\n}\n");
	const scope = placeScope(routine, routineBody(routine));
	const calls: Node[] = [];
	pairsIn(routineBody(routine), calls);
	let compared = 0;
	for (const c of calls) {
		for (const a of (c.data as CallExprData).arguments) {
			const p = placeOf(scope, a);
			assert p != null;
			assert varPath(p) == pathOf(a), `${varPath(p)} != ${pathOf(a)}`;
			compared += 1;
		}
	}
	assert compared == 6;
}
