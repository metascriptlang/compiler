import {
	Node, NodeKind, SymbolKind, SourceLocation, Symbol, Type, TypeKind, createNodeAt,
	ProgramData, ExportDeclData, ClassDeclData, ActorDeclData, DecoratedDeclData,
	MacroInvocationData, MacroDeclData, MethodDeclData, PropertyDeclData, FunctionDeclData,
	BlockStmtData, VariableDeclData, ArrowFunctionData, CallExprData, IdentifierData,
	ConstructorDeclData, ExprStmtData, BinaryExprData, MemberExprData,
} from "../../ast/node";
import { CheckerContext, Severity, addError, createContext } from "../../checker/context";
import { lookupSymbol, makeSymbol, hasFlag, markUsed, classDeclNodeOf, SymbolFlag } from "../../checker/symbol";
import { findExportedSymbol } from "../../checker/context";
import { findChar } from "../../utils/string";
import { collectOneDirective } from "../../checker/checkPass";
import { registerApplyDecorators, registerDecoratorDefers, registerApplyDecoratedStmt } from "../../checker/checkerCallbacks";
import { collectOneStatement, collectTopLevel, getDeclName } from "../../checker/collectPass";
import { isBuiltinDirective, isIntrinsicDecorator, intrinsicOnly, recordFieldDecorators } from "../../checker/decoratorHelpers";
import { ensureShaped, fillForwardSymbol } from "../../checker/resolvePass";
import { lookupModuleCtx } from "../../checker/instantiate";
import { cloneNodeForCheck } from "../../monomorphize/clone";
import { fieldInitAssignment } from "../../transform/lowering/ctorLower";
import { parseSource } from "../../parser/statements/validation";
import { callMacroEngineCompiler, callMacroBodyPreparer, setMacroDeclModulePath, pushActiveMetaCtx, popActiveMetaCtx } from "./callbacks";
import {
	clearObjectHeap, clearArrayHeap, RaiserValue, RaiserValueKind, RaiserObjectHeap, RaiserArrayHeap,
	raiserString, raiserBool, raiserNil, raiserArray,
	heapAllocArray, heapArrayPush, heapArrayLen, heapArrayGet, heapObjectGetField,
} from "../../raiser/value";
import { vmCallFunction } from "../../raiser/vm";
import { nodeToValue, valueToNode } from "./bridge";
import { forEachChild } from "../../ast/visitor";

function rebaseLocations(node: Node, loc: SourceLocation): void {
	if (node == null) return;
	node.location = loc;
	forEachChild(node, (child: Node): void => { rebaseLocations(child, loc); });
}

const applyFnName = "__decoratorApply";
const shapeVoid: int32 = 0;
const shapeNode: int32 = 1;
const shapeTransformer: int32 = 2;

interface MemberInits {
	fieldName: string;
	stmts: Node[];
}

interface ClassPlan {
	classNode: Node;
	className: string;
	isActor: boolean;
	metaKeys: string[];
	metaValues: Node[];
	inheritedKeys: string[];
	inheritedValues: Node[];
	seeded: boolean;
	memberInits: MemberInits[];
	activeInits: MemberInits;
	staticInits: Node[];
}

interface TargetInfo {
	kind: string;
	name: string;
	isStatic: boolean;
}

function hasUserDecorator(ctx: CheckerContext, decorators: Node[]): boolean {
	for (const d of decorators) {
		if (d.kind != NodeKind.MacroInvocation) continue;
		const md = d.data as MacroInvocationData;
		if (isBuiltinDirective(md.macroName) || isIntrinsicDecorator(ctx, md.macroName)) continue;
		return true;
	}
	return false;
}

function memberCarriesDecorator(ctx: CheckerContext, body: Node[]): boolean {
	for (const m of body) {
		if (m == null || m.kind != NodeKind.DecoratedDecl) continue;
		if (hasUserDecorator(ctx, (m.data as DecoratedDeclData).decorators)) return true;
	}
	return false;
}

export function decoratorRewritesStmt(ctx: CheckerContext, stmt: Node): boolean {
	let node = stmt;
	if (node != null && node.kind == NodeKind.DecoratedDecl) {
		const dd = node.data as DecoratedDeclData;
		if (hasUserDecorator(ctx, dd.decorators)) return true;
		node = dd.decoratedNode;
	}
	const decl = unwrapExport(node);
	if (decl == null) return false;
	if (decl.kind == NodeKind.ClassDecl) return memberCarriesDecorator(ctx, (decl.data as ClassDeclData).classBody);
	if (decl.kind == NodeKind.ActorDecl) return memberCarriesDecorator(ctx, (decl.data as ActorDeclData).actorBody);
	return false;
}

let _pendingStmts: Node[] = [];
let _pendingDone: boolean[] = [];
let _pendingResults: Node[] = [];
let _pendingExtras: Node[][] = [];
let _nodeMetaNodes: Node[] = [];
let _nodeMetaKeys: string[][] = [];
let _nodeMetaValues: Node[][] = [];

function applyStatementAt(ctx: CheckerContext, index: int32): void {
	if (_pendingDone[index]) return;
	_pendingDone[index] = true;
	const stmt = _pendingStmts[index];
	const after: Node[] = [];
	const deferred = decoratorRewritesStmt(ctx, stmt);
	const originalName = deferred ? deferredDeclName(stmt) : "";
	const rewritten = applyToStatement(ctx, stmt, after);
	if (deferred) finishDeferredStatement(ctx, originalName, rewritten);
	_pendingResults[index] = rewritten;
	_pendingExtras[index] = after;
}

function applyPendingClass(ctx: CheckerContext, name: string): void {
	for (let i = 0; i < _pendingStmts.length; i += 1) {
		if (_pendingDone[i]) continue;
		if (deferredDeclName(_pendingStmts[i]) != name) continue;
		applyStatementAt(ctx, i);
		return;
	}
}

export function applyDecorators(ctx: CheckerContext, program: Node): void {
	if (program.kind != NodeKind.Program) return;
	const pd = program.data as ProgramData;
	const stmts = pd.programStmts;
	const outerStmts = _pendingStmts;
	const outerDone = _pendingDone;
	const outerResults = _pendingResults;
	const outerExtras = _pendingExtras;
	_pendingStmts = stmts;
	_pendingDone = [];
	_pendingResults = [];
	_pendingExtras = [];
	for (const stmt of stmts) {
		_pendingDone.push(false);
		_pendingResults.push(stmt);
		_pendingExtras.push([]);
	}
	for (let i = 0; i < stmts.length; i += 1) applyStatementAt(ctx, i);
	const out: Node[] = [];
	for (let i = 0; i < stmts.length; i += 1) {
		out.push(_pendingResults[i]);
		for (const s of _pendingExtras[i]) out.push(s);
	}
	pd.programStmts = out;
	_pendingStmts = outerStmts;
	_pendingDone = outerDone;
	_pendingResults = outerResults;
	_pendingExtras = outerExtras;
}

function deferredDeclOf(stmt: Node): Node {
	let node = stmt;
	if (node != null && node.kind == NodeKind.DecoratedDecl) {
		node = (node.data as DecoratedDeclData).decoratedNode;
	}
	const decl = unwrapExport(node);
	if (decl == null) return null as unknown as Node;
	if (decl.kind != NodeKind.ClassDecl && decl.kind != NodeKind.ActorDecl) return null as unknown as Node;
	return decl;
}

function deferredDeclName(stmt: Node): string {
	const decl = deferredDeclOf(stmt);
	if (decl == null) return "";
	return getDeclName(decl);
}

function replacementKeepsName(ctx: CheckerContext, originalName: string, decl: Node): boolean {
	if (originalName == "" || getDeclName(decl) == originalName) return true;
	addError(ctx, `decorator replacement must keep the name '${originalName}'`, decl.location.line, decl.location.column);
	return false;
}

export function applyDecoratedStmt(ctx: CheckerContext, stmt: Node, after: Node[]): Node {
	const originalName = deferredDeclName(stmt);
	const rewritten = applyToStatement(ctx, stmt, after);
	const decl = deferredDeclOf(rewritten);
	if (decl != null && !replacementKeepsName(ctx, originalName, decl)) return stmt;
	aliasPendingMetadata(decl, stmt);
	return rewritten;
}

function finishDeferredStatement(ctx: CheckerContext, originalName: string, rewritten: Node): void {
	const decl = deferredDeclOf(rewritten);
	if (decl == null) {
		collectOneStatement(ctx, rewritten);
		return;
	}
	if (!replacementKeepsName(ctx, originalName, decl)) return;
	const sym = decl.resolvedSym;
	if (sym == null) {
		collectOneStatement(ctx, rewritten);
		return;
	}
	if (!hasFlag(sym, SymbolFlag.Forward)) return;
	sym.declNode = decl;
	fillForwardSymbol(ctx, sym);
}

function unwrapExport(node: Node): Node {
	if (node != null && node.kind == NodeKind.ExportDecl) {
		const ed = node.data as ExportDeclData;
		if (ed.exportedDecl != null) return ed.exportedDecl;
	}
	return node;
}

function applyToStatement(ctx: CheckerContext, stmt: Node, after: Node[]): Node {
	let node = stmt;
	let wrapper: Node = null as unknown as Node;
	if (node.kind == NodeKind.DecoratedDecl) {
		wrapper = node;
		node = (wrapper.data as DecoratedDeclData).decoratedNode;
		if (node == null || node.kind == NodeKind.BlockStmt) return stmt;
		for (const dec of (wrapper.data as DecoratedDeclData).decorators) collectOneDirective(ctx, dec);
	}
	const decl = unwrapExport(node);
	if (decl == null) return node;
	const isClass = decl.kind == NodeKind.ClassDecl;
	const isActor = decl.kind == NodeKind.ActorDecl;
	if (!isClass && !isActor) {
		if (wrapper != null) {
			runDecorators(ctx, (wrapper.data as DecoratedDeclData).decorators, decl, null as unknown as ClassPlan);
		}
		return node;
	}
	const plan = newPlan(ctx, decl, isActor);
	applyToMembers(ctx, plan);
	let finalDecl = decl;
	if (wrapper != null) {
		finalDecl = runDecorators(ctx, (wrapper.data as DecoratedDeclData).decorators, decl, plan);
	}
	if (finalDecl != decl) plan.classNode = finalDecl;
	finishPlan(ctx, plan, after);
	if (finalDecl != decl) {
		if (node.kind == NodeKind.ExportDecl) {
			(node.data as ExportDeclData).exportedDecl = finalDecl;
		} else {
			node = finalDecl;
		}
	}
	return node;
}

function newPlan(ctx: CheckerContext, decl: Node, isActor: boolean): ClassPlan {
	const name = isActor ? (decl.data as ActorDeclData).actorName : (decl.data as ClassDeclData).className;
	const metaKeys: string[] = [];
	const metaValues: Node[] = [];
	const inheritedKeys: string[] = [];
	const inheritedValues: Node[] = [];
	const memberInits: MemberInits[] = [];
	const staticInits: Node[] = [];
	return {
		classNode: decl,
		className: name,
		isActor: isActor,
		metaKeys: metaKeys,
		metaValues: metaValues,
		inheritedKeys: inheritedKeys,
		inheritedValues: inheritedValues,
		seeded: false,
		memberInits: memberInits,
		activeInits: null as unknown as MemberInits,
		staticInits: staticInits,
	};
}

function pendingMetadataSlot(decl: Node): int32 {
	for (let i = 0; i < _nodeMetaNodes.length; i += 1) {
		if (_nodeMetaNodes[i] == decl) return i;
	}
	return -1;
}

function recordPendingMetadata(plan: ClassPlan): void {
	const slot = pendingMetadataSlot(plan.classNode);
	if (slot >= 0) {
		_nodeMetaKeys[slot] = plan.metaKeys;
		_nodeMetaValues[slot] = plan.metaValues;
		return;
	}
	_nodeMetaNodes.push(plan.classNode);
	_nodeMetaKeys.push(plan.metaKeys);
	_nodeMetaValues.push(plan.metaValues);
}

function aliasPendingMetadata(from: Node, to: Node): void {
	if (from == null || to == null || from == to) return;
	const slot = pendingMetadataSlot(from);
	if (slot < 0) return;
	const existing = pendingMetadataSlot(to);
	if (existing >= 0) {
		_nodeMetaKeys[existing] = _nodeMetaKeys[slot];
		_nodeMetaValues[existing] = _nodeMetaValues[slot];
		return;
	}
	_nodeMetaNodes.push(to);
	_nodeMetaKeys.push(_nodeMetaKeys[slot]);
	_nodeMetaValues.push(_nodeMetaValues[slot]);
}

function addInheritedPair(plan: ClassPlan, key: string, value: Node): void {
	for (const k of plan.inheritedKeys) {
		if (k == key) return;
	}
	plan.inheritedKeys.push(key);
	plan.inheritedValues.push(value);
}

function seedInheritedMetadata(ctx: CheckerContext, plan: ClassPlan): void {
	if (plan == null || plan.seeded) return;
	plan.seeded = true;
	if (plan.isActor) return;
	let parentName = (plan.classNode.data as ClassDeclData).classExtends;
	let depth = 0;
	while (parentName != "" && depth < 64) {
		applyPendingClass(ctx, parentName);
		const parentSym = lookupSymbol(ctx.table, parentName);
		if (parentSym == null || parentSym.symbolKind != SymbolKind.Class) return;
		for (let i = 0; i < parentSym.metaKeys.length; i += 1) {
			addInheritedPair(plan, parentSym.metaKeys[i], parentSym.metaValues[i]);
		}
		const parentDecl = classDeclNodeOf(parentSym);
		if (parentDecl == null || parentDecl.kind != NodeKind.ClassDecl) return;
		const slot = pendingMetadataSlot(parentDecl);
		if (slot >= 0) {
			for (let i = 0; i < _nodeMetaKeys[slot].length; i += 1) {
				addInheritedPair(plan, _nodeMetaKeys[slot][i], _nodeMetaValues[slot][i]);
			}
		}
		parentName = (parentDecl.data as ClassDeclData).classExtends;
		depth += 1;
	}
}

function planBody(plan: ClassPlan): Node[] {
	if (plan.isActor) return (plan.classNode.data as ActorDeclData).actorBody;
	return (plan.classNode.data as ClassDeclData).classBody;
}

function memberCategory(member: Node): int32 {
	if (member.kind == NodeKind.MethodDecl) {
		return (member.data as MethodDeclData).methodIsStatic ? 0 : 1;
	}
	if (member.kind == NodeKind.PropertyDecl) {
		return (member.data as PropertyDeclData).propIsStatic ? 2 : 3;
	}
	return 4;
}

function applyToMembers(ctx: CheckerContext, plan: ClassPlan): void {
	const body = planBody(plan);
	for (let category = 0; category < 5; category += 1) {
		for (let i = 0; i < body.length; i += 1) {
			const member = body[i];
			if (member == null || member.kind != NodeKind.DecoratedDecl) continue;
			const dd = member.data as DecoratedDeclData;
			const inner = dd.decoratedNode;
			if (inner == null || memberCategory(inner) != category) continue;
			recordFieldDecorators(planClassSymbol(ctx, plan), dd);
			const stmts: Node[] = [];
			const inits: MemberInits = { fieldName: inner.kind == NodeKind.PropertyDecl ? (inner.data as PropertyDeclData).propName : "", stmts: stmts };
			plan.activeInits = inits;
			const rewritten = runDecorators(ctx, dd.decorators, inner, plan);
			plan.activeInits = null as unknown as MemberInits;
			if (stmts.length > 0) plan.memberInits.push(inits);
			const kept = intrinsicOnly(ctx, dd.decorators);
			if (kept.length == 0) {
				body[i] = rewritten;
			} else {
				dd.decorators = kept;
				dd.decoratedNode = rewritten;
			}
		}
	}
}

function decoratorPositionValid(target: Node): boolean {
	return target.kind == NodeKind.ClassDecl
		|| target.kind == NodeKind.ActorDecl
		|| target.kind == NodeKind.MethodDecl
		|| target.kind == NodeKind.PropertyDecl;
}

function runDecorators(ctx: CheckerContext, decorators: Node[], target: Node, plan: ClassPlan): Node {
	let current = target;
	for (let i = decorators.length - 1; i >= 0; i -= 1) {
		const dec = decorators[i];
		if (dec.kind != NodeKind.MacroInvocation) continue;
		const md = dec.data as MacroInvocationData;
		if (isIntrinsicDecorator(ctx, md.macroName)) continue;
		if (plan == null || current == null || !decoratorPositionValid(current)) {
			addError(ctx, "Decorators are not valid here", dec.location.line, dec.location.column);
			continue;
		}
		current = runDecorator(ctx, dec, md, current, plan);
	}
	return current;
}

function targetInfo(target: Node): TargetInfo {
	if (target.kind == NodeKind.MethodDecl) {
		const md = target.data as MethodDeclData;
		return { kind: "method", name: md.methodName, isStatic: md.methodIsStatic };
	}
	if (target.kind == NodeKind.PropertyDecl) {
		const pd = target.data as PropertyDeclData;
		return { kind: "field", name: pd.propName, isStatic: pd.propIsStatic };
	}
	if (target.kind == NodeKind.ActorDecl) {
		return { kind: "class", name: (target.data as ActorDeclData).actorName, isStatic: false };
	}
	return { kind: "class", name: (target.data as ClassDeclData).className, isStatic: false };
}

function kindLabel(kind: NodeKind): string {
	if (kind == NodeKind.ClassDecl) return "class";
	if (kind == NodeKind.ActorDecl) return "actor";
	if (kind == NodeKind.MethodDecl) return "method";
	if (kind == NodeKind.PropertyDecl) return "field";
	return "node";
}

function declaringCtx(ctx: CheckerContext, sym: Symbol): CheckerContext {
	if (sym.modulePath != "" && sym.modulePath != ctx.modulePath) {
		const other = lookupModuleCtx(sym.modulePath);
		if (other != null) return other;
	}
	return ctx;
}

function arrowReturnText(t: string): string {
	let depth: int32 = 0;
	for (let i = 0; i < t.length; i += 1) {
		const two = t.slice(i, i + 2);
		if (two == "=>" && depth == 0) return t.slice(i + 2, t.length);
		const c = t.slice(i, i + 1);
		if (c == "(" || c == "<" || c == "[" || c == "{") depth += 1;
		else if (c == ")" || c == "]" || c == "}") depth -= 1;
		else if (c == ">" && two != "=>") depth -= 1;
	}
	return "";
}

function trimText(t: string): string {
	let start: int32 = 0;
	let end: int32 = t.length;
	while (start < end && (t.slice(start, start + 1) == " " || t.slice(start, start + 1) == "\t")) start += 1;
	while (end > start && (t.slice(end - 1, end) == " " || t.slice(end - 1, end) == "\t")) end -= 1;
	return t.slice(start, end);
}

function containsArrow(t: string): boolean {
	for (let i = 0; i + 1 < t.length; i += 1) {
		if (t.slice(i, i + 2) == "=>") return true;
	}
	return false;
}

function declaringName(sym: Symbol): string {
	return sym.originalName != "" ? sym.originalName : sym.name;
}

function macroDeclNode(regCtx: CheckerContext, sym: Symbol): Node {
	if (sym.declNode != null && sym.declNode.kind == NodeKind.MacroDecl) return sym.declNode;
	const ds = lookupSymbol(regCtx.table, declaringName(sym));
	if (ds != null && ds.declNode != null && ds.declNode.kind == NodeKind.MacroDecl) return ds.declNode;
	return null as unknown as Node;
}

function macroDeclReturnRaw(decl: Node): string {
	if (decl == null) return "";
	return (decl.data as MacroDeclData).macroDeclReturnType;
}

function arrowParamCount(t: string): int32 {
	let depth: int32 = 0;
	let count: int32 = 0;
	let started = false;
	let sawAny = false;
	let i: int32 = 0;
	while (i < t.length) {
		const two = t.slice(i, i + 2);
		if (two == "=>") { i += 2; continue; }
		const c = t.slice(i, i + 1);
		i += 1;
		if (!started) {
			if (c == "(") { started = true; depth = 1; }
			continue;
		}
		if (c == "(" || c == "<" || c == "[" || c == "{") depth += 1;
		else if (c == ")" || c == ">" || c == "]" || c == "}") {
			depth -= 1;
			if (depth == 0) return sawAny ? count + 1 : 0;
		} else if (c == "," && depth == 1) count += 1;
		else if (c != " " && c != "\t") sawAny = true;
	}
	return sawAny ? count + 1 : 0;
}

function decoratorArity(sym: Symbol, decl: Node, isMacro: boolean, isFactory: boolean, regCtx: CheckerContext): int32 {
	if (isMacro) {
		if (isFactory) return arrowParamCount(macroDeclReturnRaw(decl));
		const params = regCtx.macroParamsRegistry.get(declaringName(sym));
		return params == null ? 0 : params.length;
	}
	const t = sym.symbolType;
	if (t == null || t.kind != TypeKind.Function) return 0;
	if (!isFactory) return t.typeChildren.length;
	const r = t.typeReturn;
	if (r == null || r.kind != TypeKind.Function) return 0;
	return r.typeChildren.length;
}

function macroReturnText(decl: Node, isFactory: boolean): string {
	let t = macroDeclReturnRaw(decl);
	if (isFactory) t = arrowReturnText(t);
	return trimText(t);
}

function classifyReturnText(t: string): int32 {
	if (t == "" || t == "void") return shapeVoid;
	if (containsArrow(t)) return shapeTransformer;
	return shapeNode;
}

function functionReturnType(sym: Symbol, isFactory: boolean): Type | null {
	const t = sym.symbolType;
	if (t == null || t.kind != TypeKind.Function) return null;
	let r = t.typeReturn;
	if (isFactory) {
		if (r == null || r.kind != TypeKind.Function) return null;
		r = r.typeReturn;
	}
	return r;
}

function classifyType(t: Type | null): int32 {
	if (t == null || t.kind == TypeKind.Void) return shapeVoid;
	if (t.kind == TypeKind.Function) return shapeTransformer;
	return shapeNode;
}

function wrapperSource(isMacro: boolean, paramList: string, shape: int32, arity: int32): string {
	const memberExprKind = NodeKind.MemberExpr as int32;
	const binaryExprKind = NodeKind.BinaryExpr as int32;
	const boolLitKind = NodeKind.BooleanLiteral as int32;
	let s = "function __decoratorApply(value: Node, kind: string, name: string, isStatic: boolean, isPrivate: boolean, metaKeys: string[], metaValues: Node[], inheritedKeys: string[], inheritedValues: Node[], init: Node) {\n";
	s = s + "\tconst sink: Node[] = [];\n";
	s = s + `\tconst get = (recv: Node): Node => ({ kind: ${memberExprKind}, line: recv.line, column: recv.column, object: recv, property: name, isOptional: false });\n`;
	s = s + `\tconst set = (recv: Node, v: Node): Node => ({ kind: ${binaryExprKind}, line: recv.line, column: recv.column, operator: "=", left: get(recv), right: v });\n`;
	s = s + `\tconst has = (recv: Node): Node => ({ kind: ${boolLitKind}, line: recv.line, column: recv.column, boolValue: true });\n`;
	if (isMacro) s = s + `\tconst __dec = (${paramList}) => {};\n`;
	const contextArg = arity >= 2
		? ", { kind: kind, name: name, static: isStatic, private: isPrivate, metadata: { keys: metaKeys, values: metaValues, inheritedKeys: inheritedKeys, inheritedValues: inheritedValues }, addInitializer: (stmt: Node): void => { sink.push(stmt); }, access: { get: get, set: set, has: has } }"
		: "";
	const call = "__callee__(value" + contextArg + ")";
	if (shape == shapeTransformer) {
		s = s + "\tconst r0 = " + call + ";\n\tconst r = r0(init);\n";
	} else {
		s = s + "\tconst r = " + call + ";\n";
	}
	s = s + "\treturn { result: r, initializers: sink, metaKeys: metaKeys, metaValues: metaValues };\n}\n";
	return s;
}

function calleeName(call: Node): string {
	const cd = call.data as CallExprData;
	if (cd.callee != null && cd.callee.kind == NodeKind.Identifier) return (cd.callee.data as IdentifierData).name;
	return "";
}

function buildCallee(sym: Symbol, md: MacroInvocationData, isMacro: boolean, isFactory: boolean, loc: SourceLocation): Node {
	let callee: Node = createNodeAt(NodeKind.Identifier, { name: isMacro ? "__dec" : sym.name }, loc);
	if (isFactory) {
		const factoryArgs: Node[] = [];
		for (const a of md.macroArgs) factoryArgs.push(cloneNodeForCheck(a));
		callee = createNodeAt(NodeKind.CallExpr, {
			callee: callee, arguments: factoryArgs, isDirectCall: true, resolvedOverloadIdx: -1,
		}, loc);
	}
	return callee;
}

function buildWrapper(ctx: CheckerContext, regCtx: CheckerContext, sym: Symbol, decl: Node, md: MacroInvocationData, isFactory: boolean, shape: int32, loc: SourceLocation): Node {
	const isMacro = sym.symbolKind == SymbolKind.Macro;
	const dn = declaringName(sym);
	let paramList = "";
	let macroBody: Node = null as unknown as Node;
	if (isMacro) {
		const params = regCtx.macroParamsRegistry.get(dn);
		const types = regCtx.macroParamTypesRegistry.get(dn);
		const registered = regCtx.macroBodyRegistry.get(dn);
		if (params == null || registered == null) {
			addError(ctx, `macro '${sym.name}' has no body registered in its declaring module`, loc.line, loc.column);
			return null as unknown as Node;
		}
		for (let i = 0; i < params.length; i += 1) {
			if (i > 0) paramList = paramList + ", ";
			paramList = paramList + params[i];
			if (types != null && i < types.length && types[i] != "") paramList = paramList + ": " + types[i];
		}
		macroBody = callMacroBodyPreparer(cloneNodeForCheck(registered), ctx, regCtx, dn);
	}
	const arity = decoratorArity(sym, decl, isMacro, isFactory, regCtx);
	const pr = parseSource(wrapperSource(isMacro, paramList, shape, arity));
	if (!pr.ok) {
		addError(ctx, `decorator '${sym.name}': wrapper parse failed: ${pr.error}`, loc.line, loc.column);
		return null as unknown as Node;
	}
	const program = pr.value;
	rebaseLocations(program, loc);
	const fn = (program.data as ProgramData).programStmts[0];
	const stmts = ((fn.data as FunctionDeclData).fnBody.data as BlockStmtData).statements;
	for (const st of stmts) {
		if (st.kind != NodeKind.VariableDecl) continue;
		const vd = st.data as VariableDeclData;
		if (vd.declName == "__dec" && macroBody != null && vd.initializer != null && vd.initializer.kind == NodeKind.ArrowFunction) {
			(vd.initializer.data as ArrowFunctionData).arrowBody = macroBody;
		} else if (vd.initializer != null && vd.initializer.kind == NodeKind.CallExpr && calleeName(vd.initializer) == "__callee__") {
			(vd.initializer.data as CallExprData).callee = buildCallee(sym, md, isMacro, isFactory, loc);
		}
	}
	return program;
}

function readStrings(arrHeap: RaiserArrayHeap, v: RaiserValue): string[] {
	const out: string[] = [];
	if (v.kind != RaiserValueKind.Array) return out;
	const len = heapArrayLen(arrHeap, v.intVal) as int32;
	for (let i = 0; i < len; i += 1) {
		out.push(heapArrayGet(arrHeap, v.intVal, i as number).strVal);
	}
	return out;
}

function readNodes(objHeap: RaiserObjectHeap, arrHeap: RaiserArrayHeap, v: RaiserValue, loc: SourceLocation): Node[] {
	const out: Node[] = [];
	if (v.kind != RaiserValueKind.Array) return out;
	const len = heapArrayLen(arrHeap, v.intVal) as int32;
	for (let i = 0; i < len; i += 1) {
		const item = heapArrayGet(arrHeap, v.intVal, i as number);
		if (item.kind == RaiserValueKind.Nil) continue;
		out.push(valueToNode(item, objHeap, arrHeap, loc));
	}
	return out;
}

function adoptReplacement(old: Node, replacement: Node): void {
	replacement.resolvedSym = old.resolvedSym;
	if (old.resolvedSym != null && old.resolvedSym.declNode == old) old.resolvedSym.declNode = replacement;
}

function resolveDecoratorSymbol(ctx: CheckerContext, name: string): Symbol {
	const dot = findChar(name, ".");
	if (dot < 0) return lookupSymbol(ctx.table, name);
	const head = name.slice(0, dot);
	const rest = name.slice(dot + 1, name.length);
	const ns = lookupSymbol(ctx.table, head);
	if (ns == null || ns.symbolKind != SymbolKind.Module) return null as unknown as Symbol;
	markUsed(ns);
	const info = findExportedSymbol(ctx.exportRegistry, ns.modulePath, rest);
	if (info == null) return null as unknown as Symbol;
	const sym = makeSymbol(rest, info.kind, info.symType, false);
	sym.declNode = info.declNode;
	sym.modulePath = ns.modulePath;
	return sym;
}

function runDecorator(ctx: CheckerContext, dec: Node, md: MacroInvocationData, target: Node, plan: ClassPlan): Node {
	const loc = dec.location;
	const name = md.macroName;
	const sym = resolveDecoratorSymbol(ctx, name);
	if (sym == null) {
		addError(ctx, `Cannot find name '${name}'`, loc.line, loc.column);
		return target;
	}
	if (sym.symbolKind != SymbolKind.Function && sym.symbolKind != SymbolKind.Macro) {
		addError(ctx, `'${name}' is not callable as a decorator`, loc.line, loc.column);
		return target;
	}
	markUsed(sym);
	const isMacro = sym.symbolKind == SymbolKind.Macro;
	const isFactory = md.macroHasParens;
	const regCtx = declaringCtx(ctx, sym);
	const decl = isMacro ? macroDeclNode(regCtx, sym) : (null as unknown as Node);
	if (!isMacro && (sym.symbolType == null || sym.symbolType.kind != TypeKind.Function)) ensureShaped(sym, regCtx);
	const shape = isMacro
		? classifyReturnText(macroReturnText(decl, isFactory))
		: classifyType(functionReturnType(sym, isFactory));
	const info = targetInfo(target);
	if (shape == shapeTransformer && info.kind != "field") {
		addError(ctx, `decorator '${name}' returns an initializer function, which only a field decorator may do`, loc.line, loc.column);
		return target;
	}
	const program = buildWrapper(ctx, regCtx, sym, decl, md, isFactory, shape, loc);
	if (program == null) return target;
	setMacroDeclModulePath(sym.modulePath);
	const result = callMacroEngineCompiler(program, ctx, applyFnName);
	if (result == null) {
		addError(ctx, `decorator '${name}' evaluator unavailable`, loc.line, loc.column);
		return target;
	}
	let broken = false;
	for (const e of result.errors) {
		if (e.severity != Severity.Error) continue;
		addError(ctx, `decorator '${name}': ${e.message}`, e.line, e.column);
		broken = true;
	}
	if (broken || result.funcIdx < 0) {
		if (!broken) addError(ctx, `decorator '${name}' evaluator unavailable`, loc.line, loc.column);
		return target;
	}
	const vm = result.vm;
	const objHeap = vm.objectHeap;
	const arrHeap = vm.arrayHeap;
	seedInheritedMetadata(ctx, plan);
	const keysHandle = heapAllocArray(arrHeap);
	for (const k of plan.metaKeys) heapArrayPush(arrHeap, keysHandle, raiserString(k));
	const valuesHandle = heapAllocArray(arrHeap);
	for (const v of plan.metaValues) heapArrayPush(arrHeap, valuesHandle, nodeToValue(v, objHeap, arrHeap));
	const inheritedKeysHandle = heapAllocArray(arrHeap);
	for (const k of plan.inheritedKeys) heapArrayPush(arrHeap, inheritedKeysHandle, raiserString(k));
	const inheritedValuesHandle = heapAllocArray(arrHeap);
	for (const v of plan.inheritedValues) heapArrayPush(arrHeap, inheritedValuesHandle, nodeToValue(v, objHeap, arrHeap));
	let initVal = raiserNil();
	if (target.kind == NodeKind.PropertyDecl) {
		const pd = target.data as PropertyDeclData;
		if (pd.propInitializer != null) initVal = nodeToValue(pd.propInitializer, objHeap, arrHeap);
	}
	const args: RaiserValue[] = [
		nodeToValue(target, objHeap, arrHeap),
		raiserString(info.kind), raiserString(info.name), raiserBool(info.isStatic), raiserBool(false),
		raiserArray(keysHandle), raiserArray(valuesHandle),
		raiserArray(inheritedKeysHandle), raiserArray(inheritedValuesHandle), initVal,
	];
	pushActiveMetaCtx(ctx, loc.line, loc.column);
	const res = vmCallFunction(vm, result.funcIdx, args);
	popActiveMetaCtx();
	if (vm.error != "") {
		addError(ctx, `decorator '${name}' failed: ${vm.error}`, loc.line, loc.column);
		clearObjectHeap(objHeap);
		clearArrayHeap(arrHeap);
		return target;
	}
	if (res.kind != RaiserValueKind.Object) {
		addError(ctx, `decorator '${name}' produced no result object`, loc.line, loc.column);
		clearObjectHeap(objHeap);
		clearArrayHeap(arrHeap);
		return target;
	}
	const h = res.intVal;
	plan.metaKeys = readStrings(arrHeap, heapObjectGetField(objHeap, h, "metaKeys"));
	plan.metaValues = readNodes(objHeap, arrHeap, heapObjectGetField(objHeap, h, "metaValues"), loc);
	const inits = readNodes(objHeap, arrHeap, heapObjectGetField(objHeap, h, "initializers"), loc);
	for (const s of inits) {
		if (info.isStatic || info.kind == "class" || plan.activeInits == null) plan.staticInits.push(s);
		else plan.activeInits.stmts.push(s);
	}
	const rv = heapObjectGetField(objHeap, h, "result");
	if (rv.kind == RaiserValueKind.Object) {
		const errFlag = heapObjectGetField(objHeap, rv.intVal, "__compileError");
		if (errFlag.kind == RaiserValueKind.Int && errFlag.intVal == 1) {
			const errMsg = heapObjectGetField(objHeap, rv.intVal, "message");
			const msg = errMsg.kind == RaiserValueKind.String ? errMsg.strVal : "compile error in decorator";
			const el = heapObjectGetField(objHeap, rv.intVal, "line");
			const ec = heapObjectGetField(objHeap, rv.intVal, "column");
			const line = el.kind == RaiserValueKind.Int ? el.intVal as int32 : (el.kind == RaiserValueKind.Float ? el.floatVal as int32 : loc.line);
			const column = ec.kind == RaiserValueKind.Int ? ec.intVal as int32 : (ec.kind == RaiserValueKind.Float ? ec.floatVal as int32 : loc.column);
			addError(ctx, `decorator '${name}': ${msg}`, line, column);
			clearObjectHeap(objHeap);
			clearArrayHeap(arrHeap);
			return target;
		}
	}
	let outNode = target;
	if (shape == shapeTransformer) {
		const pd = target.data as PropertyDeclData;
		pd.propInitializer = rv.kind == RaiserValueKind.Nil ? (null as unknown as Node) : valueToNode(rv, objHeap, arrHeap, loc);
	} else if (shape == shapeNode && rv.kind != RaiserValueKind.Nil) {
		const replacement = valueToNode(rv, objHeap, arrHeap, loc);
		if (replacement == null || replacement.kind != target.kind) {
			const got = replacement == null ? "nothing" : kindLabel(replacement.kind);
			const want = kindLabel(target.kind);
			const article = want == "actor" ? "an" : "a";
			addError(ctx, `decorator '${name}' on ${article} ${want} must return ${article} ${want} or nothing, got ${got}`, loc.line, loc.column);
		} else {
			adoptReplacement(target, replacement);
			outNode = replacement;
		}
	}
	clearObjectHeap(objHeap);
	clearArrayHeap(arrHeap);
	return outNode;
}

function isSuperCall(stmt: Node): boolean {
	if (stmt.kind != NodeKind.ExprStmt) return false;
	const e = (stmt.data as ExprStmtData).expr;
	if (e == null || e.kind != NodeKind.CallExpr) return false;
	return calleeName(e) == "super";
}

function bareMember(member: Node): Node {
	if (member != null && member.kind == NodeKind.DecoratedDecl) {
		const dd = member.data as DecoratedDeclData;
		if (dd.decoratedNode != null) return dd.decoratedNode;
	}
	return member;
}

function instanceFieldNames(body: Node[]): string[] {
	const names: string[] = [];
	for (const m of body) {
		const member = bareMember(m);
		if (member.kind != NodeKind.PropertyDecl) continue;
		const pd = member.data as PropertyDeclData;
		if (!pd.propIsStatic) names.push(pd.propName);
	}
	return names;
}

function instanceInitStatements(plan: ClassPlan): Node[] {
	const body = planBody(plan);
	const fields = instanceFieldNames(body);
	const out: Node[] = [];
	for (const inits of plan.memberInits) {
		let declaredField = false;
		for (const name of fields) {
			if (name == inits.fieldName) declaredField = true;
		}
		if (declaredField) continue;
		for (const s of inits.stmts) out.push(s);
	}
	for (const m of body) {
		const member = bareMember(m);
		if (member.kind != NodeKind.PropertyDecl) continue;
		const pd = member.data as PropertyDeclData;
		if (pd.propIsStatic) continue;
		if (pd.propInitializer != null) out.push(fieldInitAssignment(member, null));
		for (const inits of plan.memberInits) {
			if (inits.fieldName != pd.propName) continue;
			for (const s of inits.stmts) out.push(s);
		}
	}
	return out;
}

function injectIntoConstructor(plan: ClassPlan, stmts: Node[]): void {
	const cd = plan.classNode.data as ClassDeclData;
	let ctor: Node = null as unknown as Node;
	for (const m of cd.classBody) {
		if (m.kind == NodeKind.ConstructorDecl) ctor = m;
	}
	if (ctor == null) {
		const loc = plan.classNode.location;
		const noParams: string[] = [];
		const noTypes: string[] = [];
		const noDefaults: Node[] = [];
		const statements: Node[] = [];
		const body = createNodeAt(NodeKind.BlockStmt, { statements: statements }, loc);
		ctor = createNodeAt(NodeKind.ConstructorDecl, {
			ctorParams: noParams, ctorParamTypes: noTypes, ctorBody: body, ctorDefaults: noDefaults,
		}, loc);
		cd.classBody.push(ctor);
	}
	const body = (ctor.data as ConstructorDeclData).ctorBody.data as BlockStmtData;
	let at: int32 = 0;
	if (body.statements.length > 0 && isSuperCall(body.statements[0])) at = 1;
	const merged: Node[] = [];
	for (let i = 0; i < at; i += 1) merged.push(body.statements[i]);
	for (const s of stmts) merged.push(s);
	for (let i = at; i < body.statements.length; i += 1) merged.push(body.statements[i]);
	body.statements = merged;
}

function planClassSymbol(ctx: CheckerContext, plan: ClassPlan): Symbol {
	const sym = plan.classNode.resolvedSym;
	if (sym != null) return sym;
	return lookupSymbol(ctx.table, plan.className);
}

function finishPlan(ctx: CheckerContext, plan: ClassPlan, after: Node[]): void {
	if (plan.metaKeys.length > 0) {
		const sym = planClassSymbol(ctx, plan);
		if (sym != null) {
			sym.metaKeys = plan.metaKeys;
			sym.metaValues = plan.metaValues;
		} else {
			recordPendingMetadata(plan);
		}
	}
	if (plan.memberInits.length > 0) {
		if (plan.isActor) {
			addError(ctx, `addInitializer on actor members is not supported`, plan.classNode.location.line, plan.classNode.location.column);
		} else {
			injectIntoConstructor(plan, instanceInitStatements(plan));
		}
	}
	for (const s of plan.staticInits) after.push(s);
}

registerApplyDecorators(applyDecorators);
registerDecoratorDefers(decoratorRewritesStmt);
registerApplyDecoratedStmt(applyDecoratedStmt);

test "an intrinsic member wrapper is consumed into the method symbol before the apply pass" {
	const pr = parseSource("class Calc {\n\t@builtin(\"CalcLoud\") loud(): int32 { return 1; }\n\tn: int32 = 1;\n}\n");
	assert pr.ok;
	const ctx = createContext();
	collectTopLevel(ctx, pr.value);
	applyDecorators(ctx, pr.value);
	const cls = (pr.value.data as ProgramData).programStmts[0];
	assert cls.kind == NodeKind.ClassDecl;
	const body = (cls.data as ClassDeclData).classBody;
	assert body[0].kind == NodeKind.MethodDecl;
	assert body[0].resolvedSym != null;
	assert body[0].resolvedSym.builtinKind == "CalcLoud";
}

test "an intrinsic member wrapper beside a user decorator is consumed by the fill after the apply pass" {
	const pr = parseSource("macro keep(value: Node): Node { return value; }\n@keep\nclass Calc {\n\t@builtin(\"CalcLoud\") loud(): int32 { return 1; }\n}\n");
	assert pr.ok;
	const ctx = createContext();
	collectTopLevel(ctx, pr.value);
	const cls = (pr.value.data as ProgramData).programStmts[1];
	assert cls.kind == NodeKind.DecoratedDecl;
	const inner = (cls.data as DecoratedDeclData).decoratedNode;
	assert inner.kind == NodeKind.ClassDecl;
	assert (inner.data as ClassDeclData).classBody[0].kind == NodeKind.DecoratedDecl;
	const sym = lookupSymbol(ctx.table, "Calc");
	assert sym != null && hasFlag(sym, SymbolFlag.Forward);
	sym.declNode = inner;
	fillForwardSymbol(ctx, sym);
	const body = (inner.data as ClassDeclData).classBody;
	assert body[0].kind == NodeKind.MethodDecl;
	assert body[0].resolvedSym != null;
	assert body[0].resolvedSym.builtinKind == "CalcLoud";
}

test "an intrinsic field wrapper is recorded on the class symbol before it is stripped" {
	const pr = parseSource("class Doc {\n\t@exportName(\"doc_id\") id: string = \"\";\n\t@builtin(\"DocLoud\") loud(): int32 { return 1; }\n\tname: string = \"\";\n}\n");
	assert pr.ok;
	const ctx = createContext();
	collectTopLevel(ctx, pr.value);
	const cls = (pr.value.data as ProgramData).programStmts[0];
	const body = (cls.data as ClassDeclData).classBody;
	assert body[0].kind == NodeKind.PropertyDecl;
	const sym = lookupSymbol(ctx.table, "Doc");
	assert sym != null;
	assert sym.fieldDecoratorNames.length == 1;
	assert sym.fieldDecoratorNames[0] == "id";
	assert sym.fieldDecorators[0].length == 1;
	assert (sym.fieldDecorators[0][0].data as MacroInvocationData).macroName == "exportName";
}

function exprStmtProperty(stmt: Node): string {
	if (stmt.kind != NodeKind.ExprStmt) return "";
	const e = (stmt.data as ExprStmtData).expr;
	if (e == null || e.kind != NodeKind.BinaryExpr) return "";
	const left = (e.data as BinaryExprData).left;
	if (left == null || left.kind != NodeKind.MemberExpr) return "";
	return (left.data as MemberExprData).property;
}

test "member initializers land in the constructor in tsc order" {
	const pr = parseSource("class C {\n\ta: int32 = 1;\n\tm(): void { }\n\tb: int32 = 2;\n\tc: int32;\n\tconstructor() { }\n}\n");
	assert pr.ok;
	const ctx = createContext();
	const cls = (pr.value.data as ProgramData).programStmts[0];
	const body = (cls.data as ClassDeclData).classBody;
	const plan = newPlan(ctx, cls, false);
	const loc = cls.location;
	const mInit = createNodeAt(NodeKind.ExprStmt, { expr: createNodeAt(NodeKind.Identifier, { name: "mInit" }, loc) }, loc);
	const bInit = createNodeAt(NodeKind.ExprStmt, { expr: createNodeAt(NodeKind.Identifier, { name: "bInit" }, loc) }, loc);
	plan.memberInits.push({ fieldName: "b", stmts: [bInit] });
	plan.memberInits.push({ fieldName: "", stmts: [mInit] });
	const after: Node[] = [];
	finishPlan(ctx, plan, after);
	const ctor = (body[4].data as ConstructorDeclData).ctorBody.data as BlockStmtData;
	assert ctor.statements.length == 4;
	assert ctor.statements[0] == mInit;
	assert exprStmtProperty(ctor.statements[1]) == "a";
	assert exprStmtProperty(ctor.statements[2]) == "b";
	assert ctor.statements[3] == bInit;
	assert (body[0].data as PropertyDeclData).propInitializer == null;
	assert (body[2].data as PropertyDeclData).propInitializer == null;
	assert after.length == 0;
}

test "a class without member initializers keeps its field initializers in place" {
	const pr = parseSource("class D {\n\ta: int32 = 1;\n\tconstructor() { }\n}\n");
	assert pr.ok;
	const ctx = createContext();
	const cls = (pr.value.data as ProgramData).programStmts[0];
	const body = (cls.data as ClassDeclData).classBody;
	const plan = newPlan(ctx, cls, false);
	const after: Node[] = [];
	finishPlan(ctx, plan, after);
	assert (body[0].data as PropertyDeclData).propInitializer != null;
	assert ((body[1].data as ConstructorDeclData).ctorBody.data as BlockStmtData).statements.length == 0;
}

test "collect mints a decorated class in place" {
	const pr = parseSource("@x\nclass A {\n\tm(): void { }\n}\n\nfunction f(): void { }\n");
	assert pr.ok;
	const ctx = createContext();
	collectTopLevel(ctx, pr.value);
	const sym = lookupSymbol(ctx.table, "A");
	assert sym != null;
	assert sym.symbolKind == SymbolKind.Class;
	let classIdx = -1;
	let fnIdx = -1;
	let idx = 0;
	for (const s of ctx.table.current.symbols.values()) {
		if (s.name == "A") classIdx = idx;
		if (s.name == "f") fnIdx = idx;
		idx += 1;
	}
	assert classIdx >= 0;
	assert fnIdx >= 0;
	assert classIdx < fnIdx;
}

test "apply fills the minted class symbol exactly once" {
	const pr = parseSource("@x\nclass B {\n\tm(v: int32): void { }\n}\n");
	assert pr.ok;
	const ctx = createContext();
	collectTopLevel(ctx, pr.value);
	const before = lookupSymbol(ctx.table, "B");
	assert before != null;
	applyDecorators(ctx, pr.value);
	const after = lookupSymbol(ctx.table, "B");
	assert after == before;
	const cls = (pr.value.data as ProgramData).programStmts[0];
	assert cls.kind == NodeKind.ClassDecl;
	const md = (cls.data as ClassDeclData).classBody[0].data as MethodDeclData;
	let thisCount = 0;
	for (const p of md.methodParams) {
		if (p == "this") thisCount += 1;
	}
	assert thisCount == 1;
}
