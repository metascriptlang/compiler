import {
	Node, NodeKind, NodeFlag, DeclKind, Symbol, SymbolKind, SymbolFlag,
	ForOfStmtData, ForInStmtData, ForStmtData, WhileStmtData, DoWhileStmtData, CallExprData,
	MemberExprData, FunctionDeclData, ExprStmtData, YieldExprData, ReturnStmtData,
	TryCatchStmtData, BinaryExprData, UpdateExprData,
	HiddenDerefData, OutExprData, BreakStmtData, ContinueStmtData, IdentifierData,
	ArrayPatternData, BlockStmtData, VariableDeclData, ArrowFunctionData, FunctionExprData,
} from "../../ast/node";
import { TransformContext, freshTempSym, freshOwnedSym, newLoweredSym } from "../context";
import { walkNode, mapChildren } from "../walker";
import { forEachChild } from "../../ast/visitor";
import { cloneNodeKeepSem } from "../../monomorphize/clone";
import { isFnBoundary, isLoopKind } from "./jumpRetarget";
import { hasFlag } from "../../checker/symbol";
import { bodyIsErrorBlind } from "../../checker/raises";
import { isIterator, peelTransparentInstance } from "../../checker/types";
import { expandArrayRet, expandObjectRet } from "../desugar/destructuringLower";
import {
	makeBlock, makeVarDecl, makeIdentResolved, makeBreak, makeSwitchWrapper, makeExprStmt,
	extractBodyStmts, boolToDeclKind,
} from "../util";
import { parseInput, getStmts, makeCtx, makeJsCtx } from "../testUtil";
import { checkProgram, checkProgramJs } from "../../checker/checkPass";

interface InlineState {
	ctx: TransformContext;
	generators: HashMap<Symbol, Node>;
	recursive: HashSet<Symbol>;
	localNames: HashSet<string>;
}

interface InlineCall {
	decl: Node;
	args: Node[];
}

interface JumpPlan {
	endLabel: string;
	contLabel: string;
	loopLabel: string;
	contUsed: boolean;
}


export function lowerIterInline(program: Node, ctx: TransformContext): Node {
	const generators = new HashMap<Symbol, Node>();
	collectGenerators(program, generators);
	if (generators.size == 0) return program;
	const localNames = new HashSet<string>();
	if (ctx.jsBackend) collectLocalNames(program, true, localNames);
	const st: InlineState = { ctx, generators, recursive: recursiveGenerators(generators), localNames };
	return walkNode(program, (node: Node): Node => inlineForOf(node, st));
}

function collectGenerators(node: Node, out: HashMap<Symbol, Node>): void {
	if (node.kind == NodeKind.FunctionDecl && node.resolvedSym != null) {
		const flags = (node.data as FunctionDeclData).fnFlags;
		const plain = flags.indexOf("generator") >= 0 && flags.indexOf("async") < 0 && flags.indexOf("gen:") < 0;
		if (plain) out.set(node.resolvedSym, node);
	}
	forEachChild(node, (child: Node): void => { collectGenerators(child, out); });
}

function collectLocalNames(node: Node, moduleLevel: boolean, out: HashSet<string>): void {
	if (!moduleLevel || node.kind != NodeKind.VariableDecl) {
		match (node.kind) {
			NodeKind.VariableDecl => { out.add((node.data as VariableDeclData).declName); },
			NodeKind.TryCatchStmt => { out.add((node.data as TryCatchStmtData).catchName); },
			NodeKind.ForOfStmt => { out.add((node.data as ForOfStmtData).forOfBinding); },
			NodeKind.ForInStmt => { out.add((node.data as ForInStmtData).forInBinding); },
			NodeKind.FunctionDecl => { for (const p of (node.data as FunctionDeclData).params) { out.add(p); } },
			NodeKind.ArrowFunction => { for (const p of (node.data as ArrowFunctionData).arrowParams) { out.add(p); } },
			NodeKind.FunctionExpr => { for (const p of (node.data as FunctionExprData).funcExprParams) { out.add(p); } },
			_ => {},
		};
	}
	const isRoot = node.kind == NodeKind.Program;
	forEachChild(node, (child: Node): void => { collectLocalNames(child, isRoot, out); });
}

function collectBound(node: Node, out: HashSet<Symbol>): void {
	if (declaresSymbol(node) && node.resolvedSym != null) out.add(node.resolvedSym);
	if (node.paramSyms != null) {
		for (const p of node.paramSyms) { out.add(p); }
	}
	forEachChild(node, (child: Node): void => { collectBound(child, out); });
}

function holdsFreeName(node: Node, bound: HashSet<Symbol>, names: HashSet<string>): boolean {
	if (node.kind == NodeKind.Identifier) {
		const sym = node.resolvedSym;
		if ((sym == null || !bound.has(sym)) && names.has((node.data as IdentifierData).name)) return true;
	}
	let found = false;
	forEachChild(node, (child: Node): void => {
		if (!found && holdsFreeName(child, bound, names)) found = true;
	});
	return found;
}

function capturesLocalName(decl: Node, names: HashSet<string>): boolean {
	const bound = new HashSet<Symbol>();
	for (const p of decl.paramSyms!) { bound.add(p); }
	const body = (decl.data as FunctionDeclData).fnBody;
	collectBound(body, bound);
	return holdsFreeName(body, bound, names);
}

function recursiveGenerators(generators: HashMap<Symbol, Node>): HashSet<Symbol> {
	const recursive = new HashSet<Symbol>();
	for (const sym of generators.keys()) {
		const seen = new HashSet<Symbol>();
		const pending: Symbol[] = [sym];
		while (pending.length > 0) {
			const at = pending.pop()!;
			const decl = generators.get(at);
			if (decl == null) continue;
			const called: Symbol[] = [];
			collectCalled((decl.data as FunctionDeclData).fnBody, generators, called);
			for (const callee of called) {
				if (callee == sym) recursive.add(sym);
				if (!seen.has(callee)) {
					seen.add(callee);
					pending.push(callee);
				}
			}
		}
	}
	return recursive;
}

function collectCalled(node: Node, generators: HashMap<Symbol, Node>, out: Symbol[]): void {
	const sym = node.resolvedSym;
	const names = node.kind == NodeKind.Identifier || node.kind == NodeKind.CallExpr;
	if (names && sym != null && generators.has(sym)) out.push(sym);
	forEachChild(node, (child: Node): void => { collectCalled(child, generators, out); });
}

function inlineForOf(node: Node, st: InlineState): Node {
	if (node.kind != NodeKind.ForOfStmt) return node;
	const d = node.data as ForOfStmtData;
	const call = matchCall(d, st);
	if (call == null) return node;
	return expand(node, d, call, st);
}


function matchCall(d: ForOfStmtData, st: InlineState): InlineCall | null {
	const iterable = d.forOfIterable;
	if (iterable.kind != NodeKind.CallExpr) return null;
	const iterType = iterable.nodeType != null ? peelTransparentInstance(iterable.nodeType) : null;
	if (iterType == null || !isIterator(iterType)) return null;
	const c = iterable.data as CallExprData;
	let sym: Symbol | null = null;
	const args: Node[] = [];
	if (iterable.flags.has(NodeFlag.ExtCall)) {
		if (iterable.flags.has(NodeFlag.ExtStatic) || c.callee.kind != NodeKind.MemberExpr) return null;
		sym = iterable.resolvedSym;
		args.push((c.callee.data as MemberExprData).object);
	} else {
		if (c.callee.kind != NodeKind.Identifier) return null;
		sym = c.callee.resolvedSym;
	}
	if (sym == null) return null;
	for (const a of c.arguments) { args.push(a); }
	const decl = st.generators.get(sym);
	if (decl == null) return null;
	if (st.recursive.has(sym)) return null;
	const fd = decl.data as FunctionDeclData;
	if (decl.paramSyms == null) throw new Error(`internal: generator '${fd.fnName}' reached inlining without its parameter symbols`);
	if (decl.paramSyms.length != args.length || fd.params.length != args.length) return null;
	if (patternHasDefaults(d.forOfPattern)) return null;
	if (bodyRefusal(fd.fnBody, false, false) != "") return null;
	if (st.localNames.size > 0 && capturesLocalName(decl, st.localNames)) return null;
	return { decl, args };
}

function patternHasDefaults(pattern: Node | null): boolean {
	if (pattern == null || pattern.kind != NodeKind.ArrayPattern) return false;
	for (const def of (pattern.data as ArrayPatternData).patternDefaults) {
		if (def != null) return true;
	}
	return false;
}

function bodyRefusal(node: Node, noYield: boolean, inFn: boolean): string {
	match (node.kind) {
		NodeKind.YieldExpr => {
			if (inFn) return "";
			return "yield as a value";
		},
		NodeKind.ExprStmt => {
			const e = (node.data as ExprStmtData).expr;
			if (e.kind == NodeKind.YieldExpr && !inFn) {
				const y = e.data as YieldExprData;
				if (y.isDelegate) return "yield*";
				if (y.yieldArg == null) return "bare yield";
				if (noYield) return "yield in a finally or a try/catch";
				return bodyRefusal(y.yieldArg, noYield, inFn);
			}
		},
		NodeKind.Identifier => {
			if ((node.data as IdentifierData).name == "arguments" && node.resolvedSym == null) return "arguments";
			return "";
		},
		NodeKind.FunctionDecl | NodeKind.ClassDecl | NodeKind.ActorDecl | NodeKind.StructDecl
			| NodeKind.EnumDecl | NodeKind.InterfaceDecl | NodeKind.TypeAliasDecl | NodeKind.MethodDecl => {
			return "nested declaration";
		},
		NodeKind.DeferStmt | NodeKind.DestructuringDecl | NodeKind.AwaitExpr => {
			return "statement not lowered yet";
		},
		NodeKind.TryCatchStmt => {
			const t = node.data as TryCatchStmtData;
			if (!inFn && t.finallyBody != null && holdsYield(node) && !bodyIsErrorBlind(t.finallyBody)) {
				return "finally that may raise around a yield";
			}
			const inTry = bodyRefusal(t.tryBody, noYield || t.hasCatchClause, inFn);
			if (inTry != "") return inTry;
			if (t.hasCatchClause) {
				const inCatch = bodyRefusal(t.catchBody, noYield, inFn);
				if (inCatch != "") return inCatch;
			}
			if (t.finallyBody == null) return "";
			return bodyRefusal(t.finallyBody, true, inFn);
		},
		_ => {},
	};
	const nested = node.kind == NodeKind.ArrowFunction || node.kind == NodeKind.FunctionExpr;
	let found = "";
	forEachChild(node, (child: Node): void => {
		if (found == "") found = bodyRefusal(child, noYield, inFn || nested);
	});
	return found;
}


function expand(node: Node, d: ForOfStmtData, call: InlineCall, st: InlineState): Node {
	const ctx = st.ctx;
	const loc = node.location;
	const fd = call.decl.data as FunctionDeclData;
	const params = call.decl.paramSyms!;
	const bindingSym = node.resolvedSym;
	node.resolvedSym = null;
	const renames = new HashMap<Symbol, Symbol>();
	const out: Node[] = [];
	for (let i = 0; i < call.args.length; i += 1) {
		const param = params[i];
		const arg = call.args[i];
		if (!writesTo(fd.fnBody, param) && isStableRead(arg)) {
			renames.set(param, arg.resolvedSym!);
			continue;
		}
		const temp = freshOwnedSym(ctx, param.name, param.symbolType);
		const kind = writesTo(fd.fnBody, param) ? DeclKind.Let : DeclKind.Const;
		const bound = makeVarDecl(temp.name, arg, kind, loc);
		bound.resolvedSym = temp;
		bound.nodeType = param.symbolType;
		out.push(bound);
		renames.set(param, temp);
	}
	const body = cloneFresh(fd.fnBody, renames, ctx, true);
	const inlined = walkNode(body, (n: Node): Node => inlineForOf(n, st));
	const endLabel = freshLabel(ctx, "inl");
	const plan: JumpPlan = { endLabel, contLabel: "", loopLabel: d.forOfLabel, contUsed: false };
	const stmts = extractBodyStmts(replaceYields(inlined, d, bindingSym, plan, ctx));
	out.push(makeSwitchWrapper(stmts, endLabel, loc));
	return makeBlock(out, loc);
}

function freshLabel(ctx: TransformContext, prefix: string): string {
	ctx.tempCounter += 1;
	return `__${prefix}${ctx.tempCounter}`;
}

function isAssignOp(op: string): boolean {
	return match (op) {
		"=" | "+=" | "-=" | "*=" | "/=" | "%=" | "**=" => true,
		"&=" | "|=" | "^=" | "<<=" | ">>=" | ">>>=" | "&&=" | "||=" | "??=" => true,
		_ => false,
	};
}

function holdsYield(node: Node): boolean {
	if (node.kind == NodeKind.YieldExpr) return true;
	if (isFnBoundary(node.kind)) return false;
	let found = false;
	forEachChild(node, (child: Node): void => {
		if (!found && holdsYield(child)) found = true;
	});
	return found;
}

function mentions(node: Node, sym: Symbol): boolean {
	if (node.kind == NodeKind.Identifier && node.resolvedSym == sym) return true;
	let found = false;
	forEachChild(node, (child: Node): void => {
		if (!found && mentions(child, sym)) found = true;
	});
	return found;
}

function writesTo(node: Node, sym: Symbol): boolean {
	match (node.kind) {
		NodeKind.BinaryExpr => {
			const b = node.data as BinaryExprData;
			if (isAssignOp(b.operator) && mentions(b.left, sym)) return true;
		},
		NodeKind.UpdateExpr => {
			if (mentions((node.data as UpdateExprData).updateArg, sym)) return true;
		},
		NodeKind.HiddenAddr => {
			if (mentions((node.data as HiddenDerefData).expr, sym)) return true;
		},
		NodeKind.OutExpr => {
			if (mentions((node.data as OutExprData).outArg, sym)) return true;
		},
		_ => {},
	};
	let found = false;
	forEachChild(node, (child: Node): void => {
		if (!found && writesTo(child, sym)) found = true;
	});
	return found;
}

function isStableRead(arg: Node): boolean {
	const sym = arg.resolvedSym;
	if (arg.kind != NodeKind.Identifier || sym == null) return false;
	const local = sym.symbolKind == SymbolKind.Variable || sym.symbolKind == SymbolKind.Parameter;
	return local && !hasFlag(sym, SymbolFlag.Mutable) && !hasFlag(sym, SymbolFlag.ParamMutated)
		&& !hasFlag(sym, SymbolFlag.Global);
}


function freshLike(old: Symbol, ctx: TransformContext, unique: boolean): Symbol {
	ctx.tempCounter += 1;
	const name: string = unique ? `${old.name}__${ctx.tempCounter}` : old.name;
	const fresh = newLoweredSym(ctx, old.symbolKind, name, old.symbolType);
	fresh.symFlags = old.symFlags;
	fresh.state = old.state;
	fresh.location = old.location;
	return fresh;
}

function cloneFresh(node: Node, renames: HashMap<Symbol, Symbol>, ctx: TransformContext, unique: boolean): Node {
	const copy = cloneNodeKeepSem(node);
	copyLabels(node, copy);
	const labels = new HashMap<string, string>();
	mintDeclared(copy, renames, labels, ctx, unique);
	applyRenames(copy, renames, labels);
	return copy;
}

function copyLabels(src: Node, dst: Node): void {
	match (src.kind) {
		NodeKind.DoWhileStmt => {
			const s = src.data as DoWhileStmtData;
			const t = dst.data as DoWhileStmtData;
			t.dwLabel = s.dwLabel;
			t.dwSwitchWrapper = s.dwSwitchWrapper;
		},
		NodeKind.ForStmt => { (dst.data as ForStmtData).forLabel = (src.data as ForStmtData).forLabel; },
		NodeKind.ForOfStmt => { (dst.data as ForOfStmtData).forOfLabel = (src.data as ForOfStmtData).forOfLabel; },
		NodeKind.ForInStmt => { (dst.data as ForInStmtData).forInLabel = (src.data as ForInStmtData).forInLabel; },
		_ => {},
	};
	const from: Node[] = [];
	const to: Node[] = [];
	forEachChild(src, (child: Node): void => { from.push(child); });
	forEachChild(dst, (child: Node): void => { to.push(child); });
	if (from.length != to.length) throw new Error(`internal: a copied node of kind ${src.kind} has ${to.length} children, the original ${from.length}`);
	for (let i = 0; i < from.length; i += 1) { copyLabels(from[i], to[i]); }
}

function loopLabelOf(node: Node): string {
	return match (node.kind) {
		NodeKind.WhileStmt => (node.data as WhileStmtData).whileLabel,
		NodeKind.DoWhileStmt => (node.data as DoWhileStmtData).dwLabel,
		NodeKind.ForStmt => (node.data as ForStmtData).forLabel,
		NodeKind.ForOfStmt => (node.data as ForOfStmtData).forOfLabel,
		NodeKind.ForInStmt => (node.data as ForInStmtData).forInLabel,
		_ => "",
	};
}

function setLoopLabel(node: Node, label: string): void {
	match (node.kind) {
		NodeKind.WhileStmt => { (node.data as WhileStmtData).whileLabel = label; },
		NodeKind.DoWhileStmt => { (node.data as DoWhileStmtData).dwLabel = label; },
		NodeKind.ForStmt => { (node.data as ForStmtData).forLabel = label; },
		NodeKind.ForOfStmt => { (node.data as ForOfStmtData).forOfLabel = label; },
		NodeKind.ForInStmt => { (node.data as ForInStmtData).forInLabel = label; },
		_ => {},
	};
}

function declaresSymbol(node: Node): boolean {
	return match (node.kind) {
		NodeKind.VariableDecl | NodeKind.ForOfStmt | NodeKind.ForInStmt => true,
		NodeKind.TryCatchStmt => (node.data as TryCatchStmtData).hasCatchClause,
		_ => false,
	};
}

function mintDeclared(node: Node, renames: HashMap<Symbol, Symbol>, labels: HashMap<string, string>, ctx: TransformContext, unique: boolean): void {
	const sym = node.resolvedSym;
	if (declaresSymbol(node) && sym != null && !renames.has(sym)) renames.set(sym, freshLike(sym, ctx, unique));
	if (node.paramSyms != null) {
		for (const p of node.paramSyms) {
			if (!renames.has(p)) renames.set(p, freshLike(p, ctx, unique));
		}
	}
	const label = loopLabelOf(node);
	if (label != "" && !labels.has(label)) labels.set(label, freshLabel(ctx, "il"));
	forEachChild(node, (child: Node): void => { mintDeclared(child, renames, labels, ctx, unique); });
}

function applyRenames(node: Node, renames: HashMap<Symbol, Symbol>, labels: HashMap<string, string>): void {
	const sym = node.resolvedSym;
	if (sym != null && renames.has(sym)) {
		const renamed = renames.get(sym)!;
		node.resolvedSym = renamed;
		renameNode(node, renamed.name);
	}
	const olds = node.paramSyms;
	if (olds != null) {
		const params: Symbol[] = [];
		for (let i: int32 = 0; i < olds.length; i += 1) {
			const p: Symbol = olds[i];
			const mapped = renames.get(p);
			const to: Symbol = mapped == null ? p : mapped;
			params.push(to);
			renameParam(node, i, to.name);
		}
		node.paramSyms = params;
	}
	const label = loopLabelOf(node);
	if (label != "" && labels.has(label)) setLoopLabel(node, labels.get(label)!);
	if (node.kind == NodeKind.BreakStmt) {
		const b = node.data as BreakStmtData;
		if (b.breakLabel != "" && labels.has(b.breakLabel)) b.breakLabel = labels.get(b.breakLabel)!;
	} else if (node.kind == NodeKind.ContinueStmt) {
		const c = node.data as ContinueStmtData;
		if (c.continueLabel != "" && labels.has(c.continueLabel)) c.continueLabel = labels.get(c.continueLabel)!;
	}
	forEachChild(node, (child: Node): void => { applyRenames(child, renames, labels); });
}

function renameNode(node: Node, name: string): void {
	match (node.kind) {
		NodeKind.Identifier => { (node.data as IdentifierData).name = name; },
		NodeKind.VariableDecl => { (node.data as VariableDeclData).declName = name; },
		NodeKind.TryCatchStmt => { (node.data as TryCatchStmtData).catchName = name; },
		NodeKind.ForOfStmt => { (node.data as ForOfStmtData).forOfBinding = name; },
		NodeKind.ForInStmt => { (node.data as ForInStmtData).forInBinding = name; },
		_ => {},
	};
}

function renameParam(node: Node, at: int32, name: string): void {
	match (node.kind) {
		NodeKind.ArrowFunction => { (node.data as ArrowFunctionData).arrowParams[at] = name; },
		NodeKind.FunctionExpr => { (node.data as FunctionExprData).funcExprParams[at] = name; },
		_ => {},
	};
}


function replaceYields(node: Node, d: ForOfStmtData, bindingSym: Symbol | null, plan: JumpPlan, ctx: TransformContext): Node {
	if (node.kind == NodeKind.ExprStmt) {
		const e = (node.data as ExprStmtData).expr;
		if (e.kind == NodeKind.YieldExpr) {
			return consumerFor((e.data as YieldExprData).yieldArg, d, bindingSym, plan, ctx);
		}
	}
	if (node.kind == NodeKind.ReturnStmt) {
		const arg = (node.data as ReturnStmtData).argument;
		const leave = makeBreak(node.location);
		(leave.data as BreakStmtData).breakLabel = plan.endLabel;
		if (arg == null) return leave;
		return makeBlock([makeExprStmt(arg, node.location), leave], node.location);
	}
	if (isFnBoundary(node.kind)) return node;
	mapChildren(node, (child: Node): Node => replaceYields(child, d, bindingSym, plan, ctx));
	return node;
}

function consumerFor(value: Node, d: ForOfStmtData, bindingSym: Symbol | null, outer: JumpPlan, ctx: TransformContext): Node {
	const loc = value.location;
	const renames = new HashMap<Symbol, Symbol>();
	const stmts: Node[] = [];
	const kind = boolToDeclKind(d.forOfIsConst);
	const pattern = d.forOfPattern;
	const patKind = pattern != null ? pattern.kind : NodeKind.Identifier;
	if (patKind == NodeKind.ArrayPattern || patKind == NodeKind.ObjectPattern) {
		const elem = freshTempSym(ctx, "elem", value.nodeType);
		const elemDecl = makeVarDecl(elem.name, value, DeclKind.Const, loc);
		elemDecl.resolvedSym = elem;
		stmts.push(elemDecl);
		const base = (): Node => makeIdentResolved(elem, loc);
		const bindings = patKind == NodeKind.ArrayPattern
			? expandArrayRet(pattern, base(), kind, loc, ctx)
			: expandObjectRet(pattern, base(), kind, loc, ctx);
		for (const b of bindings) {
			const old = b.resolvedSym;
			if (old != null && !renames.has(old)) {
				const fresh = freshLike(old, ctx, false);
				renames.set(old, fresh);
				b.resolvedSym = fresh;
			}
			stmts.push(b);
		}
	} else {
		const old = bindingSym != null ? bindingSym : freshOwnedSym(ctx, d.forOfBinding, value.nodeType);
		const fresh = freshLike(old, ctx, false);
		renames.set(old, fresh);
		const bound = makeVarDecl(d.forOfBinding, value, kind, loc);
		bound.resolvedSym = fresh;
		bound.nodeType = old.symbolType != null ? old.symbolType : value.nodeType;
		stmts.push(bound);
	}
	const plan: JumpPlan = { endLabel: outer.endLabel, contLabel: freshLabel(ctx, "el"), loopLabel: outer.loopLabel, contUsed: false };
	const body = retargetConsumer(cloneFresh(d.forOfBody, renames, ctx, false), plan, false, false);
	const rest = extractBodyStmts(body);
	stmts.push(plan.contUsed ? makeSwitchWrapper(rest, plan.contLabel, loc) : makeBlock(rest, loc));
	return makeBlock(stmts, loc);
}

function isWrapper(node: Node): boolean {
	return node.kind == NodeKind.DoWhileStmt && (node.data as DoWhileStmtData).dwSwitchWrapper;
}

function retargetConsumer(node: Node, plan: JumpPlan, inLoop: boolean, inSwitch: boolean): Node {
	match (node.kind) {
		NodeKind.BreakStmt => {
			const b = node.data as BreakStmtData;
			const bare = b.breakLabel == "" && !inLoop && !inSwitch;
			if (bare || (plan.loopLabel != "" && b.breakLabel == plan.loopLabel)) b.breakLabel = plan.endLabel;
			return node;
		},
		NodeKind.ContinueStmt => {
			const c = node.data as ContinueStmtData;
			const bare = c.continueLabel == "" && !inLoop;
			if (bare || (plan.loopLabel != "" && c.continueLabel == plan.loopLabel)) {
				plan.contUsed = true;
				const leave = makeBreak(node.location);
				(leave.data as BreakStmtData).breakLabel = plan.contLabel;
				return leave;
			}
			return node;
		},
		_ => {},
	};
	if (isFnBoundary(node.kind)) return node;
	const wrapper = isWrapper(node);
	const loop = isLoopKind(node.kind) && !wrapper;
	const switching = wrapper || node.kind == NodeKind.SwitchStmt;
	mapChildren(node, (child: Node): Node => retargetConsumer(child, plan, inLoop || loop, inSwitch || switching));
	return node;
}


function lowered(src: string): Node {
	const parsed = parseInput(src);
	if (!parsed.ok) throw new Error(parsed.error);
	checkProgram(parsed.value);
	return lowerIterInline(parsed.value, makeCtx());
}

function countKind(node: Node, kind: NodeKind): int32 {
	let n: int32 = node.kind == kind ? 1 : 0;
	forEachChild(node, (child: Node): void => { n += countKind(child, kind); });
	return n;
}

test "a generator consumed in place leaves no for-of and no yield in the consumer" {
	const prog = lowered("function* count(n: int32): Iterator<int32> { for (let i = 0; i < n; i++) { yield i; } }\nlet s = 0;\nfor (const x of count(5)) { s += x; }");
	const stmts = getStmts(prog);
	assert stmts[2].kind == NodeKind.BlockStmt;
	assert countKind(stmts[2], NodeKind.ForOfStmt) == 0;
	assert countKind(stmts[2], NodeKind.YieldExpr) == 0;
}

function stillForOf(src: string): boolean {
	const stmts = getStmts(lowered(src));
	return stmts[stmts.length - 1].kind == NodeKind.ForOfStmt;
}

test "a yield read as a value keeps the closure path" {
	assert stillForOf("function* g(): Iterator<int32> { const v = yield 1; }\nfor (const x of g()) { }");
}

test "yield* keeps the closure path" {
	assert stillForOf("function* h(): Iterator<int32> { yield 1; }\nfunction* g(): Iterator<int32> { yield* h(); }\nfor (const x of g()) { }");
}

test "a yield in a finally keeps the closure path" {
	assert stillForOf("function* g(): Iterator<int32> { try { yield 1; } finally { yield 2; } }\nfor (const x of g()) { }");
}

test "a yield inside a try with a catch keeps the closure path" {
	assert stillForOf("function* g(): Iterator<int32> { try { yield 1; } catch (e) { } }\nfor (const x of g()) { }");
}

test "a yield inside a try with only a finally is inlined" {
	assert !stillForOf("function* g(): Iterator<int32> { try { yield 1; } finally { } }\nfor (const x of g()) { }");
}

test "a generator that calls itself keeps the closure path" {
	assert stillForOf("function* g(n: int32): Iterator<int32> { for (const x of g(n)) { yield x; } }\nfor (const x of g(1)) { }");
}

test "a stored generator keeps the closure path" {
	assert stillForOf("function* g(): Iterator<int32> { yield 1; }\nconst it = g();\nfor (const x of it) { }");
}

test "two expansions of one generator declare disjoint symbols" {
	const prog = lowered("function* g(): Iterator<int32> { const k = 1; yield k; }\nfor (const a of g()) { }\nfor (const b of g()) { }");
	const stmts = getStmts(prog);
	const first = declaredSyms(stmts[1]);
	const second = declaredSyms(stmts[2]);
	assert first.length > 0 && first.length == second.length;
	for (let a = 0; a < first.length; a++) {
		for (let b = 0; b < second.length; b++) { assert first[a] != second[b]; }
	}
}

function declaredSyms(node: Node): Symbol[] {
	const out: Symbol[] = [];
	collectDeclared(node, out);
	return out;
}

function collectDeclared(node: Node, out: Symbol[]): void {
	if (node.kind == NodeKind.VariableDecl && node.resolvedSym != null) out.push(node.resolvedSym);
	forEachChild(node, (child: Node): void => { collectDeclared(child, out); });
}

test "a consumer break leaves the whole expansion by label" {
	const prog = lowered("function* g(): Iterator<int32> { yield 1; yield 2; }\nfor (const x of g()) { if (x == 1) break; }");
	const block = getStmts(prog)[1];
	const wrapper = ((block.data as BlockStmtData).statements)[0];
	assert wrapper.kind == NodeKind.DoWhileStmt;
	assert findBreakLabel(wrapper) == (wrapper.data as DoWhileStmtData).dwLabel;
}

function findBreakLabel(node: Node): string {
	if (node.kind == NodeKind.BreakStmt) return (node.data as BreakStmtData).breakLabel;
	let found = "";
	forEachChild(node, (child: Node): void => {
		if (found == "") found = findBreakLabel(child);
	});
	return found;
}

test "a copy keeps the label of every loop kind it duplicates" {
	const prog = lowered("function* g(): Iterator<int32> { for (let i = 0; i < 2; i++) { if (i == 0) continue; yield i; } }\nfor (const a of g()) { }\nfor (const b of g()) { }");
	const stmts = getStmts(prog);
	assert loopLabels(stmts[1]).length == loopLabels(stmts[2]).length;
	const left = loopLabels(stmts[1]);
	const right = loopLabels(stmts[2]);
	for (let a = 0; a < left.length; a++) {
		for (let b = 0; b < right.length; b++) { assert left[a] != right[b]; }
	}
}

function loopLabels(node: Node): string[] {
	const out: string[] = [];
	collectLoopLabels(node, out);
	return out;
}

function collectLoopLabels(node: Node, out: string[]): void {
	const label = loopLabelOf(node);
	if (label != "") out.push(label);
	forEachChild(node, (child: Node): void => { collectLoopLabels(child, out); });
}

function namesIn(node: Node, out: string[]): void {
	if (node.kind == NodeKind.Identifier) out.push((node.data as IdentifierData).name);
	if (node.kind == NodeKind.VariableDecl) out.push((node.data as VariableDeclData).declName);
	forEachChild(node, (child: Node): void => { namesIn(child, out); });
}

test "on the JS backend the copy names its parameter and locals apart from the original" {
	const parsed = parseInput("function* g(n: int32): Iterator<int32> { for (let i = 0; i < n; i++) { yield i; } }\nfor (const a of g(2)) { }");
	if (!parsed.ok) throw new Error(parsed.error);
	checkProgramJs(parsed.value);
	const stmts = getStmts(lowerIterInline(parsed.value, makeJsCtx()));
	const names: string[] = [];
	namesIn(stmts[1], names);
	assert names.length > 0;
	let clashes = 0;
	for (let k = 0; k < names.length; k++) {
		if (names[k] == "n" || names[k] == "i") clashes += 1;
	}
	assert clashes == 0;
}
