import {
	Node, NodeKind, SymbolKind, SourceLocation, Symbol, Type, TypeKind, createNodeAt,
	ProgramData, ExportDeclData, ClassDeclData, ActorDeclData, DecoratedDeclData,
	MacroInvocationData, MacroDeclData, MethodDeclData, PropertyDeclData, FunctionDeclData,
	BlockStmtData, VariableDeclData, ArrowFunctionData, CallExprData, IdentifierData,
	ConstructorDeclData, ExprStmtData,
} from "../../ast/node";
import { CheckerContext, Severity, addError, createContext } from "../../checker/context";
import { lookupSymbol, makeSymbol, hasFlag, SymbolFlag } from "../../checker/symbol";
import { findExportedSymbol } from "../../checker/context";
import { findChar } from "../../utils/string";
import { collectOneDirective } from "../../checker/checkPass";
import { registerApplyDecorators, registerDecoratorDefers } from "../../checker/checkerCallbacks";
import { collectOneStatement, collectTopLevel, getDeclName } from "../../checker/collectPass";
import { ensureShaped, fillForwardSymbol } from "../../checker/resolvePass";
import { lookupModuleCtx } from "../../checker/instantiate";
import { cloneNodeForCheck } from "../../monomorphize/clone";
import { parseSource } from "../../parser/statements/validation";
import { callMacroEngineCompiler, callMacroBodyPreparer, setMacroDeclModulePath } from "./callbacks";
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

const passThroughDirectives: string[] = [
	"emit", "include", "compile", "link", "passC", "passL", "import",
	"comptime", "runtime", "builtin", "cImport",
];
const intrinsicDecorators: string[] = ["pure", "nonisolated", "awaitable", "affineAwaitable"];
const applyFnName = "__decoratorApply";
const shapeVoid: int32 = 0;
const shapeNode: int32 = 1;
const shapeTransformer: int32 = 2;

interface ClassPlan {
	classNode: Node;
	className: string;
	isActor: boolean;
	metaKeys: string[];
	metaValues: Node[];
	instanceInits: Node[];
	staticInits: Node[];
}

interface TargetInfo {
	kind: string;
	name: string;
	isStatic: boolean;
}

export function isBuiltinDirective(name: string): boolean {
	for (const n of passThroughDirectives) {
		if (n == name) return true;
	}
	return false;
}

function isIntrinsicDecorator(name: string): boolean {
	if (isBuiltinDirective(name)) return true;
	for (const n of intrinsicDecorators) {
		if (n == name) return true;
	}
	return false;
}

function hasUserDecorator(decorators: Node[]): boolean {
	for (const d of decorators) {
		if (d.kind != NodeKind.MacroInvocation) continue;
		const md = d.data as MacroInvocationData;
		if (isBuiltinDirective(md.macroName) || isIntrinsicDecorator(md.macroName)) continue;
		return true;
	}
	return false;
}

function memberCarriesDecorator(body: Node[]): boolean {
	for (const m of body) {
		if (m == null || m.kind != NodeKind.DecoratedDecl) continue;
		if (hasUserDecorator((m.data as DecoratedDeclData).decorators)) return true;
	}
	return false;
}

export function decoratorRewritesStmt(stmt: Node): boolean {
	let node = stmt;
	if (node != null && node.kind == NodeKind.DecoratedDecl) {
		const dd = node.data as DecoratedDeclData;
		if (hasUserDecorator(dd.decorators)) return true;
		node = dd.decoratedNode;
	}
	const decl = unwrapExport(node);
	if (decl == null) return false;
	if (decl.kind == NodeKind.ClassDecl) return memberCarriesDecorator((decl.data as ClassDeclData).classBody);
	if (decl.kind == NodeKind.ActorDecl) return memberCarriesDecorator((decl.data as ActorDeclData).actorBody);
	return false;
}

export function applyDecorators(ctx: CheckerContext, program: Node): void {
	if (program.kind != NodeKind.Program) return;
	const pd = program.data as ProgramData;
	const out: Node[] = [];
	for (const stmt of pd.programStmts) {
		const after: Node[] = [];
		const deferred = decoratorRewritesStmt(stmt);
		const originalName = deferred ? deferredDeclName(stmt) : "";
		const rewritten = applyToStatement(ctx, stmt, after);
		if (deferred) finishDeferredStatement(ctx, originalName, rewritten);
		out.push(rewritten);
		for (const s of after) out.push(s);
	}
	pd.programStmts = out;
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

function finishDeferredStatement(ctx: CheckerContext, originalName: string, rewritten: Node): void {
	const decl = deferredDeclOf(rewritten);
	if (decl == null) {
		collectOneStatement(ctx, rewritten);
		return;
	}
	const name = getDeclName(decl);
	if (originalName != "" && name != originalName) {
		addError(ctx, `decorator replacement must keep the name '${originalName}'`, decl.location.line, decl.location.column);
		return;
	}
	const sym = decl.resolvedSym;
	if (sym == null) {
		collectOneStatement(ctx, rewritten);
		return;
	}
	if (!hasFlag(sym, SymbolFlag.Forward)) return;
	sym.declNode = decl;
	fillForwardSymbol(ctx, sym);
}

function intrinsicOnly(decorators: Node[]): Node[] {
	const kept: Node[] = [];
	for (const d of decorators) {
		if (d.kind == NodeKind.MacroInvocation && !isIntrinsicDecorator((d.data as MacroInvocationData).macroName)) continue;
		kept.push(d);
	}
	return kept;
}

function rewrapStatement(wrapper: Node, node: Node): Node {
	if (wrapper == null) return node;
	const dd = wrapper.data as DecoratedDeclData;
	const kept = intrinsicOnly(dd.decorators);
	if (kept.length == 0) return node;
	dd.decorators = kept;
	dd.decoratedNode = node;
	return wrapper;
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
		return rewrapStatement(wrapper, node);
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
	return rewrapStatement(wrapper, node);
}

function newPlan(ctx: CheckerContext, decl: Node, isActor: boolean): ClassPlan {
	const name = isActor ? (decl.data as ActorDeclData).actorName : (decl.data as ClassDeclData).className;
	const metaKeys: string[] = [];
	const metaValues: Node[] = [];
	const instanceInits: Node[] = [];
	const staticInits: Node[] = [];
	return {
		classNode: decl,
		className: name,
		isActor: isActor,
		metaKeys: metaKeys,
		metaValues: metaValues,
		instanceInits: instanceInits,
		staticInits: staticInits,
	};
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
			const rewritten = runDecorators(ctx, dd.decorators, inner, plan);
			const kept = intrinsicOnly(dd.decorators);
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
		|| target.kind == NodeKind.MethodDecl
		|| target.kind == NodeKind.PropertyDecl;
}

function runDecorators(ctx: CheckerContext, decorators: Node[], target: Node, plan: ClassPlan): Node {
	let current = target;
	for (let i = decorators.length - 1; i >= 0; i -= 1) {
		const dec = decorators[i];
		if (dec.kind != NodeKind.MacroInvocation) continue;
		const md = dec.data as MacroInvocationData;
		if (isIntrinsicDecorator(md.macroName)) continue;
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
	return { kind: "class", name: (target.data as ClassDeclData).className, isStatic: false };
}

function kindLabel(kind: NodeKind): string {
	if (kind == NodeKind.ClassDecl) return "class";
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

function wrapperSource(isMacro: boolean, paramList: string, returnAnnotation: string, shape: int32, arity: int32): string {
	const memberExprKind = NodeKind.MemberExpr as int32;
	const binaryExprKind = NodeKind.BinaryExpr as int32;
	const boolLitKind = NodeKind.BooleanLiteral as int32;
	let s = "function __decoratorApply(value: Node, kind: string, name: string, isStatic: boolean, isPrivate: boolean, metaKeys: string[], metaValues: Node[], init: Node) {\n";
	s = s + "\tconst sink: Node[] = [];\n";
	s = s + `\tconst get = (recv: Node): Node => ({ kind: ${memberExprKind}, line: recv.line, column: recv.column, object: recv, property: name, isOptional: false });\n`;
	s = s + `\tconst set = (recv: Node, v: Node): Node => ({ kind: ${binaryExprKind}, line: recv.line, column: recv.column, operator: "=", left: get(recv), right: v });\n`;
	s = s + `\tconst has = (recv: Node): Node => ({ kind: ${boolLitKind}, line: recv.line, column: recv.column, boolValue: true });\n`;
	if (isMacro) s = s + `\tconst __dec = (${paramList})${returnAnnotation} => {};\n`;
	const contextArg = arity >= 2
		? ", { kind: kind, name: name, static: isStatic, private: isPrivate, metadata: { keys: metaKeys, values: metaValues }, addInitializer: (stmt: Node): void => { sink.push(stmt); }, access: { get: get, set: set, has: has } }"
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
	let returnAnnotation = "";
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
		const rt = macroReturnText(decl, false);
		if (rt != "") returnAnnotation = ": " + rt;
		macroBody = callMacroBodyPreparer(cloneNodeForCheck(registered), ctx, regCtx, dn);
	}
	const arity = decoratorArity(sym, decl, isMacro, isFactory, regCtx);
	const pr = parseSource(wrapperSource(isMacro, paramList, returnAnnotation, shape, arity));
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
	const keysHandle = heapAllocArray(arrHeap);
	for (const k of plan.metaKeys) heapArrayPush(arrHeap, keysHandle, raiserString(k));
	const valuesHandle = heapAllocArray(arrHeap);
	for (const v of plan.metaValues) heapArrayPush(arrHeap, valuesHandle, nodeToValue(v, objHeap, arrHeap));
	let initVal = raiserNil();
	if (target.kind == NodeKind.PropertyDecl) {
		const pd = target.data as PropertyDeclData;
		if (pd.propInitializer != null) initVal = nodeToValue(pd.propInitializer, objHeap, arrHeap);
	}
	const args: RaiserValue[] = [
		nodeToValue(target, objHeap, arrHeap),
		raiserString(info.kind), raiserString(info.name), raiserBool(info.isStatic), raiserBool(false),
		raiserArray(keysHandle), raiserArray(valuesHandle), initVal,
	];
	const res = vmCallFunction(vm, result.funcIdx, args);
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
		if (info.isStatic || info.kind == "class") plan.staticInits.push(s);
		else plan.instanceInits.push(s);
	}
	const rv = heapObjectGetField(objHeap, h, "result");
	let outNode = target;
	if (shape == shapeTransformer) {
		const pd = target.data as PropertyDeclData;
		pd.propInitializer = rv.kind == RaiserValueKind.Nil ? (null as unknown as Node) : valueToNode(rv, objHeap, arrHeap, loc);
	} else if (shape == shapeNode && rv.kind != RaiserValueKind.Nil) {
		const replacement = valueToNode(rv, objHeap, arrHeap, loc);
		if (replacement == null || replacement.kind != target.kind) {
			const got = replacement == null ? "nothing" : kindLabel(replacement.kind);
			addError(ctx, `decorator '${name}' on a ${info.kind} must return a ${info.kind} or nothing, got ${got}`, loc.line, loc.column);
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

function injectIntoConstructor(plan: ClassPlan): void {
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
	for (const s of plan.instanceInits) merged.push(s);
	for (let i = at; i < body.statements.length; i += 1) merged.push(body.statements[i]);
	body.statements = merged;
}

function finishPlan(ctx: CheckerContext, plan: ClassPlan, after: Node[]): void {
	if (plan.instanceInits.length > 0) {
		if (plan.isActor) {
			addError(ctx, `addInitializer on actor members is not supported`, plan.classNode.location.line, plan.classNode.location.column);
		} else {
			injectIntoConstructor(plan);
		}
	}
	for (const s of plan.staticInits) after.push(s);
}

registerApplyDecorators(applyDecorators);
registerDecoratorDefers(decoratorRewritesStmt);

test "member wrappers with intrinsic decorators survive the apply pass" {
	const pr = parseSource("class Calc {\n\t@pure loud(): int32 { return 1; }\n\tn: int32 = 1;\n}\n");
	assert pr.ok;
	const ctx = createContext();
	applyDecorators(ctx, pr.value);
	const cls = (pr.value.data as ProgramData).programStmts[0];
	assert cls.kind == NodeKind.ClassDecl;
	const body = (cls.data as ClassDeclData).classBody;
	assert body[0].kind == NodeKind.DecoratedDecl;
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
