import {
	Node, NodeKind, NodeFlag, DeclKind, Symbol, SymbolKind, SymbolFlag, SourceLocation, Type, TypeKind,
	ProgramData, IfStmtData, ForOfStmtData, ForInStmtData, ForStmtData, WhileStmtData, DoWhileStmtData, CallExprData,
	MemberExprData, UnaryExprData, NewExprData, ArrayLiteralData, ArrayAccessData, HiddenStdConvData, FunctionDeclData, ExprStmtData, YieldExprData, ReturnStmtData,
	TryCatchStmtData, BinaryExprData, UpdateExprData, ConditionalExprData, InlineFrame,
	HiddenDerefData, OutExprData, BreakStmtData, ContinueStmtData, IdentifierData,
	ArrayPatternData, BlockStmtData, VariableDeclData, TypeAssertionData, ArrowFunctionData, FunctionExprData, isEmptyBlock,
} from "../../ast/node";
import { TransformContext, freshTempSym, freshOwnedSym, newLoweredSym } from "../context";
import { walkNode, mapChildren, hasEffect } from "../walker";
import { forEachChild } from "../../ast/visitor";
import { cloneNodeKeepSem } from "../../monomorphize/clone";
import { isLoopKind } from "./jumpRetarget";
import { isRoutineOrTestNode } from "../../ast/shape";
import { hasFlag, symbolKey } from "../../checker/symbol";
import { placedInstanceOf, placedInstances } from "../../checker/instantiate";
import { isStaticExtensionFlag } from "../../checker/context";
import { bodyIsErrorBlind } from "../../checker/raises";
import { isIterator, peelTransparentInstance } from "../../checker/types";
import { expandArrayRet, expandObjectRet } from "../desugar/destructuringLower";
import { Spiller, lowerAssign, lowerOperandList } from "./operandOrder";
import { sameType } from "../../checker/compat";
import {
	makeBlock, makeVarDecl, makeIdentResolved, makeBreak, makeSwitchWrapper, makeExprStmt,
	extractBodyStmts, boolToDeclKind, makeNull, makeAssign,
} from "../util";
import { parseInput, getStmts, makeCtx, makeJsCtx } from "../testUtil";
import { checkProgram, checkProgramJs } from "../../checker/checkPass";
import { recordBodyRead } from "../../checker/bodyReads";
import { hostRoutineKey } from "../../module/tiers";
import { lookupHost } from "../../raiser/hostRegistry";

interface InlineState {
	ctx: TransformContext;
	generators: HashMap<Symbol, Node>;
	ownConsumers: HashMap<Symbol, Node>;
	ownForwarders: HashMap<Symbol, Node>;
	recursive: HashSet<Symbol>;
	expanding: HashSet<Symbol>;
	fromCaller: HashSet<Node>;
	localNames: HashSet<string>;
	stored: HashMap<Symbol, StoredChain>;
}

interface StoredChain {
	init: Node;
	prelude: Node[];
	loc: SourceLocation;
	used: boolean;
}

interface InlineCall {
	decl: Node;
	args: Node[];
	foreign: boolean;
}

interface CallTarget {
	sym: Symbol;
	args: Node[];
	isStatic: boolean;
}

interface ConsumerExpansion {
	stmts: Node[];
	result: Symbol | null;
}

interface JumpPlan {
	endLabel: string;
	contLabel: string;
	loopLabel: string;
	contUsed: boolean;
}


class ModuleOffers {
	generators: HashMap<string, Node> = new HashMap<string, Node>();
	consumers: HashMap<string, Node> = new HashMap<string, Node>();
	forwarders: HashMap<string, Node> = new HashMap<string, Node>();
}

const _offers = new HashMap<string, ModuleOffers>();
const _offerHomes = new HashMap<string, string[]>();
const _offerNames = new HashSet<string>();

export function offerIterBodies(program: Node, ctx: TransformContext): void {
	const modulePath = ownModule(ctx);
	const generators = new HashMap<Symbol, Node>();
	const consumers = new HashMap<Symbol, Node>();
	const forwarders = new HashMap<Symbol, Node>();
	collectInlinable(program, generators, consumers, forwarders);
	const previous = _offers.get(modulePath);
	if (previous != null) {
		for (const kept of [previous.generators, previous.consumers, previous.forwarders]) {
			for (const key of kept.keys()) dropHome(key, modulePath);
		}
	}
	const offers = new ModuleOffers();
	offerBodies(generators, offers.generators, modulePath);
	offerBodies(consumers, offers.consumers, modulePath);
	offerBodies(forwarders, offers.forwarders, modulePath);
	_offers.set(modulePath, offers);
}

function ownModule(ctx: TransformContext): string {
	return ctx.checkerCtx != null ? ctx.checkerCtx.modulePath : "";
}

function offerKey(sym: Symbol): string | null {
	if (sym.modulePath == "" || hasFlag(sym, SymbolFlag.Anon) || hasFlag(sym, SymbolFlag.StaticLocal)) return null;
	return symbolKey(sym);
}

function dropHome(key: string, modulePath: string): void {
	const homes = _offerHomes.get(key);
	if (homes == null) return;
	const at = homes.indexOf(modulePath);
	if (at >= 0) homes.splice(at, 1);
}

function offerBodies(decls: HashMap<Symbol, Node>, offered: HashMap<string, Node>, modulePath: string): void {
	for (const sym of decls.keys()) {
		const key = offerKey(sym);
		if (key == null) continue;
		offered.set(key, keptBody(decls.get(sym)!));
		_offerNames.add(sym.name);
		const homes = _offerHomes.get(key);
		if (homes == null) _offerHomes.set(key, [modulePath]);
		else if (!homes.includes(modulePath)) homes.push(modulePath);
	}
}

function keptBody(decl: Node): Node {
	const copy = cloneNodeKeepSem(decl);
	copyLabels(decl, copy);
	return copy;
}

function seesModule(ctx: TransformContext, modulePath: string): boolean {
	return ctx.importClosure == null || modulePath == ownModule(ctx) || ctx.importClosure!.has(modulePath);
}

function offersGenerators(ctx: TransformContext): boolean {
	for (const modulePath of _offers.keys()) {
		if (_offers.get(modulePath)!.generators.size > 0 && seesModule(ctx, modulePath)) return true;
	}
	return false;
}

enum OfferKind { Generator, Consumer, Forwarder }

function offeredBody(sym: Symbol, kind: OfferKind, st: InlineState): Node | null {
	recordBodyRead(sym.modulePath);
	if (!_offerNames.has(sym.name)) return null;
	const key = offerKey(sym);
	const homes = key != null ? _offerHomes.get(key!) : null;
	if (homes == null) return null;
	let home = "";
	for (const modulePath of homes) {
		if (seesModule(st.ctx, modulePath) && (home == "" || modulePath < home)) home = modulePath;
	}
	if (home == "") return null;
	recordBodyRead(home);
	if (st.ctx.reloadableModules.indexOf(home) >= 0) return null;
	const offers = _offers.get(home)!;
	const table = kind == OfferKind.Generator ? offers.generators : kind == OfferKind.Consumer ? offers.consumers : offers.forwarders;
	return table.get(key!);
}

export function lowerIterInline(program: Node, ctx: TransformContext): Node {
	const generators = new HashMap<Symbol, Node>();
	const consumers = new HashMap<Symbol, Node>();
	const forwarders = new HashMap<Symbol, Node>();
	collectInlinable(program, generators, consumers, forwarders);
	if (generators.size == 0 && !offersGenerators(ctx)) return program;
	const localNames = new HashSet<string>();
	if (ctx.jsBackend) collectLocalNames(program, true, localNames);
	const ownConsumers = new HashMap<Symbol, Node>();
	const ownForwarders = new HashMap<Symbol, Node>();
	for (const sym of consumers.keys()) ownConsumers.set(sym, keptBody(consumers.get(sym)!));
	for (const sym of forwarders.keys()) ownForwarders.set(sym, keptBody(forwarders.get(sym)!));
	const st: InlineState = {
		ctx, generators, ownConsumers, ownForwarders, recursive: recursiveGenerators(generators), expanding: new HashSet<Symbol>(), fromCaller: new HashSet<Node>(),
		localNames, stored: new HashMap<Symbol, StoredChain>(),
	};
	collectStored(program, st);
	return walkNode(program, (node: Node): Node => inlineStmt(node, st));
}

function collectStored(node: Node, st: InlineState): void {
	if (node.kind == NodeKind.Program) collectStoredIn((node.data as ProgramData).programStmts, st);
	else if (node.kind == NodeKind.BlockStmt) collectStoredIn((node.data as BlockStmtData).statements, st);
	forEachChild(node, (child: Node): void => { collectStored(child, st); });
}

function collectStoredIn(stmts: Node[], st: InlineState): void {
	for (let i = 0; i < stmts.length; i += 1) {
		const s = stmts[i];
		if (singleUseChain(stmts, i, st)) {
			const init = (s.data as VariableDeclData).initializer;
			st.stored.set(s.resolvedSym!, { init, prelude: [], loc: s.location, used: false });
		}
	}
}

function singleUseChain(stmts: Node[], at: int32, st: InlineState): boolean {
	const s = stmts[at];
	const sym = s.resolvedSym;
	if (s.kind != NodeKind.VariableDecl || sym == null || hasFlag(sym, SymbolFlag.Exported)) return false;
	const d = s.data as VariableDeclData;
	const init = d.initializer;
	if (d.declKind != DeclKind.Const || init == null || !sameType(sym.symbolType, init.nodeType)) return false;
	if (matchIterable(init, st) == null) return false;
	let reads: int32 = 0;
	let once = false;
	for (let i = 0; i < stmts.length; i += 1) {
		const n = readCount(stmts[i], sym);
		reads += n;
		if (i > at && n == 1) once = readOutsideLoops(stmts[i], sym);
	}
	return reads == 1 && once;
}

function storedRead(arg: Node, st: InlineState): StoredChain | null {
	const sym = arg.kind == NodeKind.Identifier ? arg.resolvedSym : null;
	return sym != null ? st.stored.get(sym) : null;
}

function collectInlinable(
	node: Node,
	generators: HashMap<Symbol, Node>,
	consumers: HashMap<Symbol, Node>,
	forwarders: HashMap<Symbol, Node>,
): void {
	if (node.kind == NodeKind.FunctionDecl && node.resolvedSym != null) {
		const fd = node.data as FunctionDeclData;
		const generator = fd.fnFlags.indexOf("generator") >= 0;
		const plain = fd.fnFlags.indexOf("async") < 0 && fd.fnFlags.indexOf("gen:") < 0;
		if (plain && generator) generators.set(node.resolvedSym, node);
		const fn = plain && !generator && fd.fnBody != null;
		if (fn && returnsIterator(node)) forwarders.set(node.resolvedSym, node);
		else if (fn && takesIterator(node)) consumers.set(node.resolvedSym, node);
	}
	forEachChild(node, (child: Node): void => { collectInlinable(child, generators, consumers, forwarders); });
}

function isIteratorType(t: Type | null): boolean {
	return t != null && isIterator(peelTransparentInstance(t));
}

function takesIterator(decl: Node): boolean {
	if (decl.paramSyms == null) return false;
	for (const p of decl.paramSyms) {
		if (isIteratorType(p.symbolType)) return true;
	}
	return false;
}

function returnsIterator(decl: Node): boolean {
	const t = decl.resolvedSym!.symbolType;
	return t != null && isIteratorType(t.typeReturn);
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

function inlineStmt(node: Node, st: InlineState): Node {
	match (node.kind) {
		NodeKind.ForOfStmt => {
			const d = node.data as ForOfStmtData;
			const call = matchCall(d, st);
			if (call != null && storedRead(d.forOfIterable, st) != null) {
				d.forOfIterable = boundSource(d.forOfIterable, call, [], st, node.location);
				return inlineStmt(node, st);
			}
			if (call != null) return isGenerator(call.decl) ? expand(node, d, call, st) : forwardFor(node, d, call, st);
		},
		NodeKind.ExprStmt => {
			const e = (node.data as ExprStmtData).expr;
			const stored = assignsLocal(e);
			const call = underProjections(stored ? (e.data as BinaryExprData).right : e);
			const consumer = matchConsumer(call, st);
			if (consumer != null && stored && (e.data as BinaryExprData).operator != "=") {
				const pre: Node[] = [];
				lowerAssign(consumerSpiller(call, consumer, st), e, pre);
				pre.push(node);
				return makeBlock(pre, node.location);
			}
			if (consumer != null) {
				const r = expandConsumer(consumer, call.nodeType, st, node.location);
				if (stored && r.result != null) {
					const b = e.data as BinaryExprData;
					b.right = replaceUnderProjections(b.right, makeIdentResolved(r.result, node.location));
					r.stmts.push(node);
				} else if (call != e && r.result != null) {
					(node.data as ExprStmtData).expr = replaceUnderProjections(e, makeIdentResolved(r.result, node.location));
					r.stmts.push(node);
				}
				return makeBlock(r.stmts, node.location);
			}
			const pre = hoistFromStatement(e, st);
			if (pre != null) {
				pre.push(node);
				return makeBlock(pre, node.location);
			}
		},
		NodeKind.ReturnStmt => {
			const arg = (node.data as ReturnStmtData).argument;
			const call = arg != null ? underProjections(arg) : null;
			const consumer = call != null ? matchConsumer(call, st) : null;
			if (consumer != null) {
				const r = expandConsumer(consumer, call!.nodeType, st, node.location);
				if (r.result != null) (node.data as ReturnStmtData).argument = replaceUnderProjections(arg!, makeIdentResolved(r.result, node.location));
				r.stmts.push(node);
				return makeBlock(r.stmts, node.location);
			}
			if (arg != null && holdsConsumer(arg, st) && orderSafe(arg, st)) {
				const pre: Node[] = [];
				(node.data as ReturnStmtData).argument = hoistConsumers(arg, pre, st);
				pre.push(node);
				return makeBlock(pre, node.location);
			}
		},
		NodeKind.Program => {
			const d = node.data as ProgramData;
			node.data = { programStmts: spliceConsumerDecls(d.programStmts, st) };
		},
		NodeKind.BlockStmt => {
			const d = node.data as BlockStmtData;
			node.data = { statements: spliceConsumerDecls(d.statements, st) };
		},
		_ => {},
	};
	return node;
}

// A cast, or a read of a field of the consumer's result, runs after the consumer and nothing else
// runs before it, so the consumer expands where it stands and the wrapper reads its result.
function underProjections(e: Node): Node {
	if (e.kind == NodeKind.TypeAssertion) return underProjections((e.data as TypeAssertionData).asExpr);
	if (e.kind == NodeKind.HiddenDeref) return underProjections((e.data as HiddenDerefData).expr);
	if (e.kind == NodeKind.MemberExpr && !(e.data as MemberExprData).isOptional) return underProjections((e.data as MemberExprData).object);
	return e;
}

function replaceUnderProjections(e: Node, result: Node): Node {
	if (e.kind == NodeKind.TypeAssertion) {
		const d = e.data as TypeAssertionData;
		d.asExpr = replaceUnderProjections(d.asExpr, result);
	} else if (e.kind == NodeKind.HiddenDeref) {
		const d = e.data as HiddenDerefData;
		d.expr = replaceUnderProjections(d.expr, result);
	} else if (e.kind == NodeKind.MemberExpr && !(e.data as MemberExprData).isOptional) {
		const d = e.data as MemberExprData;
		d.object = replaceUnderProjections(d.object, result);
	} else {
		return result;
	}
	return e;
}

// A consumer inside an operand list runs where it stands in the evaluation order: each operand written
// before it is bound to a temp first (operandOrder), so a call or a read it could change is settled
// first. A statement whose earlier operand has an effect no temp can hold keeps its closure path.
function consumerOperand(e: Node, st: InlineState): InlineCall | null {
	const call = underProjections(e);
	if (call.kind != NodeKind.CallExpr || call.nodeType == null || call.nodeType.kind == TypeKind.Void) return null;
	const target = callTarget(call);
	if (target == null || (!st.ownConsumers.has(target.sym) && !_offerNames.has(target.sym.name))) return null;
	return matchConsumer(call, st);
}

function operandsOf(e: Node): Node[] | null {
	if (e.kind == NodeKind.CallExpr) {
		const d = e.data as CallExprData;
		if (d.callee.kind == NodeKind.MemberExpr && (d.callee.data as MemberExprData).isOptional) return null;
		const ops: Node[] = [d.callee.kind == NodeKind.MemberExpr ? (d.callee.data as MemberExprData).object : d.callee];
		for (const a of d.arguments) { ops.push(a); }
		return ops;
	}
	if (e.kind == NodeKind.BinaryExpr) {
		const d = e.data as BinaryExprData;
		if (isAssignOp(d.operator) || d.operator == "&&" || d.operator == "||" || d.operator == "??") return null;
		return [d.left, d.right];
	}
	if (e.kind == NodeKind.ArrayAccess) return [(e.data as ArrayAccessData).array, (e.data as ArrayAccessData).index];
	if (e.kind == NodeKind.ArrayLiteral) return (e.data as ArrayLiteralData).elements;
	if (e.kind == NodeKind.NewExpr) return (e.data as NewExprData).newArguments;
	return null;
}

function wrapped(e: Node): Node | null {
	if (e.kind == NodeKind.TypeAssertion) return (e.data as TypeAssertionData).asExpr;
	if (e.kind == NodeKind.HiddenStdConv || e.kind == NodeKind.HiddenSubConv) return (e.data as HiddenStdConvData).convExpr;
	if (e.kind == NodeKind.HiddenDeref) return (e.data as HiddenDerefData).expr;
	if (e.kind == NodeKind.UnaryExpr) return (e.data as UnaryExprData).operand;
	if (e.kind == NodeKind.MemberExpr && !(e.data as MemberExprData).isOptional) return (e.data as MemberExprData).object;
	return null;
}

function holdsConsumer(e: Node, st: InlineState): boolean {
	if (consumerOperand(e, st) != null) return true;
	const ops = operandsOf(e);
	if (ops != null) {
		for (const op of ops) {
			if (op != null && holdsConsumer(op, st)) return true;
		}
		return false;
	}
	const inner = wrapped(e);
	return inner != null && holdsConsumer(inner, st);
}

function bindsItsEffects(e: Node): boolean {
	if (e.kind == NodeKind.HiddenDeref) return bindsItsEffects((e.data as HiddenDerefData).expr);
	if (e.kind == NodeKind.CallExpr || e.kind == NodeKind.NewExpr || e.kind == NodeKind.UnaryExpr || e.kind == NodeKind.UpdateExpr) return true;
	return e.kind == NodeKind.BinaryExpr && !isAssignOp((e.data as BinaryExprData).operator);
}

function orderSafe(e: Node, st: InlineState): boolean {
	if (consumerOperand(e, st) != null) return true;
	const ops = operandsOf(e);
	if (ops == null) {
		const inner = wrapped(e);
		return inner == null || orderSafe(inner, st);
	}
	let last = -1;
	for (let i = 0; i < ops.length; i += 1) {
		if (ops[i] != null && holdsConsumer(ops[i], st)) last = i;
	}
	for (let i = 0; i <= last; i += 1) {
		const op = ops[i];
		if (op == null) continue;
		if (i < last && hasEffect(op) && !bindsItsEffects(op) && !holdsConsumer(op, st)) return false;
		if (!orderSafe(op, st)) return false;
	}
	return true;
}

function hoistConsumers(e: Node, pre: Node[], st: InlineState): Node {
	const consumer = consumerOperand(e, st);
	if (consumer != null) {
		const call = underProjections(e);
		const r = expandConsumer(consumer, call.nodeType, st, e.location);
		const res = r.result;
		if (res == null) throw new Error("internal: a consumer in an operand has no result");
		for (const s of r.stmts) { pre.push(s); }
		return replaceUnderProjections(e, makeIdentResolved(res, e.location));
	}
	const sp: Spiller = { ctx: st.ctx, has: (n: Node): boolean => holdsConsumer(n, st), lower: (n: Node, out: Node[]): Node => hoistConsumers(n, out, st) };
	if (operandsOf(e) != null) {
		lowerOperandList(sp, e, pre);
		return e;
	}
	if (e.kind == NodeKind.TypeAssertion) {
		const d = e.data as TypeAssertionData;
		d.asExpr = hoistConsumers(d.asExpr, pre, st);
	} else if (e.kind == NodeKind.HiddenStdConv || e.kind == NodeKind.HiddenSubConv) {
		const d = e.data as HiddenStdConvData;
		d.convExpr = hoistConsumers(d.convExpr, pre, st);
	} else if (e.kind == NodeKind.HiddenDeref) {
		const d = e.data as HiddenDerefData;
		d.expr = hoistConsumers(d.expr, pre, st);
	} else if (e.kind == NodeKind.UnaryExpr) {
		const d = e.data as UnaryExprData;
		d.operand = hoistConsumers(d.operand, pre, st);
	} else if (e.kind == NodeKind.MemberExpr && !(e.data as MemberExprData).isOptional) {
		const d = e.data as MemberExprData;
		d.object = hoistConsumers(d.object, pre, st);
	}
	return e;
}

function hoistFromStatement(e: Node, st: InlineState): Node[] | null {
	const pre: Node[] = [];
	if (e.kind == NodeKind.BinaryExpr && isAssignOp((e.data as BinaryExprData).operator)) {
		const b = e.data as BinaryExprData;
		if (b.operator == "&&=" || b.operator == "||=" || b.operator == "??=") return null;
		if (!holdsConsumer(b.right, st) || !orderSafe(b.right, st)) return null;
		const sp: Spiller = { ctx: st.ctx, has: (n: Node): boolean => holdsConsumer(n, st), lower: (n: Node, out: Node[]): Node => hoistConsumers(n, out, st) };
		lowerAssign(sp, e, pre);
		return pre;
	}
	if (!holdsConsumer(e, st) || !orderSafe(e, st)) return null;
	hoistConsumers(e, pre, st);
	return pre;
}

function assignsLocal(e: Node): boolean {
	if (e.kind != NodeKind.BinaryExpr) return false;
	const b = e.data as BinaryExprData;
	const conditional = b.operator == "&&=" || b.operator == "||=" || b.operator == "??=";
	return isAssignOp(b.operator) && !conditional && b.left.kind == NodeKind.Identifier;
}

function consumerSpiller(call: Node, consumer: InlineCall, st: InlineState): Spiller {
	return {
		ctx: st.ctx,
		has: (n: Node): boolean => underProjections(n) == call,
		lower: (n: Node, pre: Node[]): Node => {
			if (underProjections(n) != call) return n;
			const r = expandConsumer(consumer, call.nodeType, st, n.location);
			const res = r.result;
			if (res == null) throw new Error("internal: a compound assignment from a consumer with no result");
			for (const s of r.stmts) { pre.push(s); }
			return replaceUnderProjections(n, makeIdentResolved(res, n.location));
		},
	};
}

function spliceConsumerDecls(stmts: Node[], st: InlineState): Node[] {
	const out: Node[] = [];
	for (const stmt of stmts) {
		const init = stmt.kind == NodeKind.VariableDecl ? (stmt.data as VariableDeclData).initializer : null;
		const call = init != null ? underProjections(init) : null;
		const consumer = call != null ? matchConsumer(call, st) : null;
		if (consumer == null) {
			if (init != null && holdsConsumer(init, st) && orderSafe(init, st)) {
				const pre: Node[] = [];
				(stmt.data as VariableDeclData).initializer = hoistConsumers(init, pre, st);
				for (const s of pre) { out.push(s); }
			}
			out.push(stmt);
			continue;
		}
		const r = expandConsumer(consumer, call!.nodeType, st, stmt.location);
		if (r.result != null) (stmt.data as VariableDeclData).initializer = replaceUnderProjections(init!, makeIdentResolved(r.result, stmt.location));
		for (const s of r.stmts) { out.push(s); }
		out.push(stmt);
	}
	return withStoredPreludes(out, st);
}

function withStoredPreludes(stmts: Node[], st: InlineState): Node[] {
	const out: Node[] = [];
	for (const stmt of stmts) {
		const stored = stmt.kind == NodeKind.VariableDecl && stmt.resolvedSym != null ? st.stored.get(stmt.resolvedSym) : null;
		if (stored == null || !stored.used) {
			out.push(stmt);
			continue;
		}
		for (const s of stored.prelude) { out.push(s); }
	}
	return out;
}


function matchCall(d: ForOfStmtData, st: InlineState): InlineCall | null {
	if (patternHasDefaults(d.forOfPattern)) return null;
	return matchIterable(d.forOfIterable, st);
}

function matchIterable(iterable: Node, st: InlineState): InlineCall | null {
	const stored = storedRead(iterable, st);
	if (stored != null) return matchIterable(stored.init, st);
	if (iterable.kind != NodeKind.CallExpr) return null;
	const iterType = iterable.nodeType != null ? peelTransparentInstance(iterable.nodeType) : null;
	if (iterType == null || !isIterator(iterType)) return null;
	const target = callTarget(iterable);
	if (target == null) return null;
	const sym = target.sym;
	let decl: Node | null = null;
	if (st.generators.has(sym)) decl = st.generators.get(sym)!;
	else if (st.ownForwarders.has(sym)) decl = st.ownForwarders.get(sym)!;
	else decl = foreignBody(sym, OfferKind.Generator, st) ?? foreignBody(sym, OfferKind.Forwarder, st);
	if (decl == null || st.recursive.has(sym) || !inlinable(decl, target, st.fromCaller.has(iterable), st)) return null;
	if (!isGenerator(decl) && !forwards(decl)) return null;
	return { decl, args: target.args, foreign: !st.generators.has(sym) && !st.ownForwarders.has(sym) };
}

function isGenerator(decl: Node): boolean {
	return (decl.data as FunctionDeclData).fnFlags.indexOf("generator") >= 0;
}

function forwards(decl: Node): boolean {
	const stmts = extractBodyStmts((decl.data as FunctionDeclData).fnBody);
	if (stmts.length == 0) return false;
	const last = stmts[stmts.length - 1];
	if (last.kind != NodeKind.ReturnStmt) return false;
	const arg = (last.data as ReturnStmtData).argument;
	if (arg == null || arg.kind != NodeKind.CallExpr) return false;
	for (let i = 0; i < stmts.length - 1; i += 1) {
		if (holdsReturn(stmts[i])) return false;
	}
	return true;
}

function holdsReturn(node: Node): boolean {
	if (node.kind == NodeKind.ReturnStmt) return true;
	if (isRoutineOrTestNode(node)) return false;
	let found = false;
	forEachChild(node, (child: Node): void => {
		if (!found && holdsReturn(child)) found = true;
	});
	return found;
}

function matchConsumer(call: Node, st: InlineState): InlineCall | null {
	if (call.kind != NodeKind.CallExpr) return null;
	const target = callTarget(call);
	if (target == null) return null;
	const sym = target.sym;
	const decl = st.ownConsumers.has(sym) ? st.ownConsumers.get(sym)! : foreignBody(sym, OfferKind.Consumer, st);
	if (decl == null || !inlinable(decl, target, false, st)) return null;
	const body = (decl.data as FunctionDeclData).fnBody;
	const params = decl.paramSyms!;
	for (let i = 0; i < params.length; i += 1) {
		if (!writesTo(body, params[i]) && chainSource(body, params[i], target.args[i], st) != null) {
			return { decl, args: target.args, foreign: !st.ownConsumers.has(sym) };
		}
	}
	return null;
}

function callTarget(call: Node): CallTarget | null {
	const c = call.data as CallExprData;
	let sym: Symbol | null = null;
	const args: Node[] = [];
	const isStatic = call.flags.has(NodeFlag.ExtStatic);
	if (call.flags.has(NodeFlag.ExtCall)) {
		if (c.callee.kind != NodeKind.MemberExpr) return null;
		sym = call.resolvedSym;
		if (passesReceiver(call)) args.push((c.callee.data as MemberExprData).object);
	} else {
		if (c.callee.kind != NodeKind.Identifier) return null;
		sym = c.callee.resolvedSym;
	}
	if (sym == null) return null;
	for (const a of c.arguments) { args.push(a); }
	return { sym: placedInstanceOf(placedInstances(), sym), args, isStatic };
}

function passesReceiver(call: Node): boolean {
	return call.flags.has(NodeFlag.ExtCall) && !call.flags.has(NodeFlag.ExtStatic);
}

function inlinable(decl: Node, target: CallTarget, fromCaller: boolean, st: InlineState): boolean {
	if (!fromCaller && st.expanding.has(target.sym)) return false;
	const fd = decl.data as FunctionDeclData;
	if (decl.paramSyms == null) throw new Error(`internal: '${fd.fnName}' reached inlining without its parameter symbols`);
	if (target.isStatic && !isStaticExtensionFlag(fd.fnFlags)) {
		throw new Error(`internal: a static call reached '${fd.fnName}', which is not a static extension`);
	}
	const n = target.args.length;
	if (decl.paramSyms.length != n || fd.params.length != n) return false;
	if (bodyRefusal(fd.fnBody, false, false) != "") return false;
	return st.localNames.size == 0 || !capturesLocalName(decl, st.localNames);
}

function foreignBody(sym: Symbol, kind: OfferKind, st: InlineState): Node | null {
	if (st.ctx.reloadableModules.indexOf(sym.modulePath) >= 0) {
		recordBodyRead(sym.modulePath);
		return null;
	}
	const decl = offeredBody(sym, kind, st);
	if (decl == null || writesModuleState(decl)) return null;
	return decl;
}

function writesModuleState(decl: Node): boolean {
	const body = (decl.data as FunctionDeclData).fnBody;
	const globals = new HashSet<Symbol>();
	collectGlobals(body, globals);
	for (const g of globals) {
		if (writesTo(body, g)) return true;
	}
	return false;
}

function collectGlobals(node: Node, out: HashSet<Symbol>): void {
	const sym = node.kind == NodeKind.Identifier ? node.resolvedSym : null;
	if (sym != null && hasFlag(sym, SymbolFlag.Global)) out.add(sym);
	forEachChild(node, (child: Node): void => { collectGlobals(child, out); });
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
	const loc = node.location;
	const bindingSym = node.resolvedSym;
	node.resolvedSym = null;
	const out: Node[] = [];
	const inlined = expandedBody(call, inlinedBody(call, out, st, loc), st);
	const endLabel = freshLabel(st.ctx, "inl");
	const plan: JumpPlan = { endLabel, contLabel: "", loopLabel: d.forOfLabel, contUsed: false };
	const stmts = extractBodyStmts(replaceYields(inlined, d, bindingSym, plan, st.ctx));
	out.push(makeSwitchWrapper(stmts, endLabel, loc));
	return makeBlock(out, loc);
}

function forwardFor(node: Node, d: ForOfStmtData, call: InlineCall, st: InlineState): Node {
	const out: Node[] = [];
	d.forOfIterable = forwardedSource(call, out, st, node.location);
	out.push(inlineStmt(node, st));
	return makeBlock(out, node.location);
}

function forwardedSource(call: InlineCall, out: Node[], st: InlineState, loc: SourceLocation): Node {
	const stmts = extractBodyStmts(expandedBody(call, inlinedBody(call, out, st, loc), st));
	const ret = stmts.pop()!;
	for (const s of stmts) { out.push(s); }
	const returned = (ret.data as ReturnStmtData).argument!;
	const sym = call.decl.resolvedSym!;
	st.expanding.add(sym);
	const inner = matchIterable(returned, st);
	const source = inner != null ? boundSource(returned, inner, out, st, loc) : null;
	st.expanding.delete(sym);
	if (source != null) return source;
	const temp = freshOwnedSym(st.ctx, "fwd", returned.nodeType);
	const decl = makeVarDecl(temp.name, returned, DeclKind.Const, loc);
	decl.resolvedSym = temp;
	out.push(decl);
	return makeIdentResolved(temp, loc);
}

function expandConsumer(call: InlineCall, returned: Type | null, st: InlineState, loc: SourceLocation): ConsumerExpansion {
	const ctx = st.ctx;
	const stmts: Node[] = [];
	let result: Symbol | null = null;
	if (returned != null && returned.kind != TypeKind.Void) {
		result = freshOwnedSym(ctx, "res", returned);
		const decl = makeVarDecl(result.name, makeNull(loc), DeclKind.Let, loc);
		decl.resolvedSym = result;
		decl.nodeType = returned;
		stmts.push(decl);
	}
	const out: Node[] = [];
	const endLabel = freshLabel(ctx, "cinl");
	const body = returnsAsBreaks(inlinedBody(call, out, st, loc), result, endLabel);
	out.push(makeSwitchWrapper(extractBodyStmts(expandedBody(call, body, st)), endLabel, loc));
	stmts.push(makeBlock(out, loc));
	return { stmts, result };
}

function expandedBody(call: InlineCall, body: Node, st: InlineState): Node {
	const sym = call.decl.resolvedSym!;
	st.expanding.add(sym);
	const inlined = walkNode(body, (n: Node): Node => inlineStmt(n, st));
	st.expanding.delete(sym);
	return inlined;
}

function inlinedBody(call: InlineCall, out: Node[], st: InlineState, loc: SourceLocation): Node {
	const ctx = st.ctx;
	const fd = call.decl.data as FunctionDeclData;
	const params = call.decl.paramSyms!;
	const renames = new HashMap<Symbol, Symbol>();
	const sources = new HashMap<Symbol, Node>();
	for (let i = 0; i < call.args.length; i += 1) {
		const param = params[i];
		const arg = call.args[i];
		const writes = writesTo(fd.fnBody, param);
		if (!writes && isStableRead(arg) && storedRead(arg, st) == null) {
			renames.set(param, arg.resolvedSym!);
			continue;
		}
		const source = writes ? null : chainSource(fd.fnBody, param, arg, st);
		if (source != null) {
			sources.set(param, boundSource(arg, source, out, st, loc));
			continue;
		}
		const temp = freshOwnedSym(ctx, param.name, param.symbolType);
		const bound = makeVarDecl(temp.name, arg, writes ? DeclKind.Let : DeclKind.Const, loc);
		bound.resolvedSym = temp;
		bound.nodeType = param.symbolType;
		out.push(bound);
		renames.set(param, temp);
	}
	const copy = cloneFresh(fd.fnBody, renames, ctx, true);
	if (call.foreign) relocate(copy, loc);
	return walkNode(copy, (n: Node): Node => {
		const read = n.kind == NodeKind.Identifier ? n.resolvedSym : null;
		if (read == null || !sources.has(read)) return n;
		const copy = cloneNodeKeepSem(sources.get(read)!);
		markCalls(copy, st.fromCaller);
		return copy;
	});
}

function relocate(node: Node, loc: SourceLocation): void {
	node.location = loc;
	forEachChild(node, (child: Node): void => { relocate(child, loc); });
}

function markCalls(node: Node, out: HashSet<Node>): void {
	if (node.kind == NodeKind.CallExpr) out.add(node);
	forEachChild(node, (child: Node): void => { markCalls(child, out); });
}

function chainSource(body: Node, param: Symbol, arg: Node, st: InlineState): InlineCall | null {
	if (!readOncePerPath(body, param)) return null;
	return matchIterable(arg, st);
}

function readOncePerPath(body: Node, param: Symbol): boolean {
	let main = false;
	for (const s of extractBodyStmts(body)) {
		const n = readCount(s, param);
		if (n == 0) continue;
		if (main || n != 1) return false;
		if (leavesAfterRead(s, param)) continue;
		if (!readOutsideLoops(s, param)) return false;
		main = true;
	}
	return main;
}

function leavesAfterRead(s: Node, param: Symbol): boolean {
	if (s.kind != NodeKind.IfStmt) return false;
	const d = s.data as IfStmtData;
	if (!isEmptyBlock(d.alternate) || mentions(d.condition, param) || holdsYield(d.consequent)) return false;
	const stmts = extractBodyStmts(d.consequent);
	const last = stmts[stmts.length - 1];
	const leaves = last.kind == NodeKind.ThrowStmt || last.kind == NodeKind.ReturnStmt;
	return leaves && readOutsideLoops(d.consequent, param);
}

function readOutsideLoops(node: Node, sym: Symbol): boolean {
	if (node.kind == NodeKind.Identifier && node.resolvedSym == sym) return true;
	if (node.kind == NodeKind.ForOfStmt && readOutsideLoops((node.data as ForOfStmtData).forOfIterable, sym)) return true;
	if (isRoutineOrTestNode(node) || (isLoopKind(node.kind) && !isWrapper(node))) return false;
	let found = false;
	forEachChild(node, (child: Node): void => {
		if (!found && readOutsideLoops(child, sym)) found = true;
	});
	return found;
}

function boundSource(arg: Node, source: InlineCall, out: Node[], st: InlineState, loc: SourceLocation): Node {
	const stored = storedRead(arg, st);
	if (stored != null) {
		if (stored.used) throw new Error("internal: a single-use iterator const was read twice");
		stored.used = true;
		return boundSource(stored.init, source, stored.prelude, st, stored.loc);
	}
	if (!isGenerator(source.decl)) return forwardedSource(source, out, st, loc);
	const fd = source.decl.data as FunctionDeclData;
	const params = source.decl.paramSyms!;
	const bound: Node[] = [];
	for (let i = 0; i < source.args.length; i += 1) {
		const a = source.args[i];
		const p = params[i];
		const inner = writesTo(fd.fnBody, p) ? null : chainSource(fd.fnBody, p, a, st);
		if (isStableRead(a) && storedRead(a, st) == null) {
			bound.push(a);
		} else if (inner != null) {
			bound.push(boundSource(a, inner, out, st, loc));
		} else {
			const temp = freshOwnedSym(st.ctx, p.name, p.symbolType);
			const decl = makeVarDecl(temp.name, a, DeclKind.Const, loc);
			decl.resolvedSym = temp;
			decl.nodeType = p.symbolType;
			out.push(decl);
			bound.push(makeIdentResolved(temp, loc));
		}
	}
	const c = arg.data as CallExprData;
	const receiver = passesReceiver(arg);
	if (receiver) (c.callee.data as MemberExprData).object = bound[0];
	c.arguments = receiver ? bound.slice(1) : bound;
	return arg;
}

function readCount(node: Node, sym: Symbol): int32 {
	let n: int32 = node.kind == NodeKind.Identifier && node.resolvedSym == sym ? 1 : 0;
	forEachChild(node, (child: Node): void => { n += readCount(child, sym); });
	return n;
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
	if (isRoutineOrTestNode(node)) return false;
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

export function cloneFresh(node: Node, renames: HashMap<Symbol, Symbol>, ctx: TransformContext, unique: boolean): Node {
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
	if (node == null) return node;
	if (node.kind == NodeKind.ExprStmt) {
		const e = (node.data as ExprStmtData).expr;
		if (e.kind == NodeKind.YieldExpr) {
			return consumerFor((e.data as YieldExprData).yieldArg, d, bindingSym, plan, ctx);
		}
	}
	if (node.kind == NodeKind.ReturnStmt) return returnAsBreak(node, null, plan.endLabel);
	if (isRoutineOrTestNode(node)) return node;
	mapChildren(node, (child: Node): Node => replaceYields(child, d, bindingSym, plan, ctx));
	return node;
}

function returnsAsBreaks(node: Node, result: Symbol | null, endLabel: string): Node {
	if (node == null) return node;
	if (node.kind == NodeKind.ReturnStmt) return returnAsBreak(node, result, endLabel);
	if (isRoutineOrTestNode(node)) return node;
	mapChildren(node, (child: Node): Node => returnsAsBreaks(child, result, endLabel));
	return node;
}

function returnAsBreak(node: Node, result: Symbol | null, endLabel: string): Node {
	const loc = node.location;
	const arg = (node.data as ReturnStmtData).argument;
	const leave = makeBreak(loc);
	(leave.data as BreakStmtData).breakLabel = endLabel;
	if (arg == null) return leave;
	const value = result != null ? makeAssign(makeIdentResolved(result, loc), arg, loc) : arg;
	return makeBlock([makeExprStmt(value, loc), leave], loc);
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
	if (node == null) return node;
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
	if (isRoutineOrTestNode(node)) return node;
	const wrapper = isWrapper(node);
	const loop = isLoopKind(node.kind) && !wrapper;
	const switching = wrapper || node.kind == NodeKind.SwitchStmt;
	mapChildren(node, (child: Node): Node => retargetConsumer(child, plan, inLoop || loop, inSwitch || switching));
	return node;
}

export class CallInlining {
	reloadable: string[];
	leaves: HashMap<string, Node> = new HashMap<string, Node>();
	constructor(reloadable: string[]) {
		this.reloadable = reloadable;
	}
}

const LEAF_NODE_LIMIT: int32 = 30;

interface LeafState {
	inlining: CallInlining;
	own: HashMap<Symbol, Node>;
	checked: HashSet<Symbol>;
	leafDecls: HashMap<Symbol, Node>;
}

export function lowerCallInline(program: Node, inlining: CallInlining): Node {
	const st: LeafState = { inlining, own: new HashMap<Symbol, Node>(), checked: new HashSet<Symbol>(), leafDecls: new HashMap<Symbol, Node>() };
	collectRoutines(program, st.own);
	for (const sym of st.own.keys()) ownLeaf(sym, st);
	const result = inlineLeafCalls(program, st);
	for (const sym of st.leafDecls.keys()) {
		const key = offerKey(sym);
		if (key == null) continue;
		inlining.leaves.set(key, cloneNodeKeepSem(st.leafDecls.get(sym)!));
	}
	return result;
}

function collectRoutines(node: Node, out: HashMap<Symbol, Node>): void {
	if (node.kind == NodeKind.FunctionDecl && node.resolvedSym != null && (node.data as FunctionDeclData).fnBody != null) out.set(node.resolvedSym, node);
	forEachChild(node, (child: Node): void => { collectRoutines(child, out); });
}

function ownLeaf(sym: Symbol, st: LeafState): Node | null {
	if (st.leafDecls.has(sym)) return st.leafDecls.get(sym);
	if (st.checked.has(sym)) return null;
	st.checked.add(sym);
	const decl = st.own.get(sym)!;
	const fd = decl.data as FunctionDeclData;
	fd.fnBody = inlineLeafCalls(fd.fnBody, st);
	if (leafValue(decl) == null) return null;
	st.leafDecls.set(sym, decl);
	return decl;
}

function foreignLeaf(sym: Symbol, st: LeafState): Node | null {
	const origin = sym.instantiatedFrom != null ? sym.instantiatedFrom : sym;
	if (st.inlining.reloadable.includes(sym.modulePath) || st.inlining.reloadable.includes(origin.modulePath)) return null;
	const key = offerKey(sym);
	return key != null ? st.inlining.leaves.get(key) : null;
}

function inlineLeafCalls(node: Node, st: LeafState): Node {
	if (node == null) return node;
	if (node.kind == NodeKind.FunctionDecl && node.resolvedSym != null && st.checked.has(node.resolvedSym)) return node;
	mapChildren(node, (child: Node): Node => inlineLeafCalls(child, st));
	if (node.kind != NodeKind.CallExpr) return node;
	const inlined = inlinedCall(node, st);
	return inlined != null ? inlined : node;
}

function inlinedCall(call: Node, st: LeafState): Node | null {
	const target = callTarget(call);
	if (target == null || target.sym.symbolKind != SymbolKind.Function) return null;
	const decl = st.own.has(target.sym) ? ownLeaf(target.sym, st) : foreignLeaf(target.sym, st);
	if (decl == null) return null;
	const fd = decl.data as FunctionDeclData;
	const params = decl.paramSyms!;
	const value = leafValue(decl);
	if (value == null || params.length != target.args.length || !sameType(value.nodeType, call.nodeType)) return null;
	for (let i = 0; i < params.length; i += 1) {
		if (!passesAsIs(target.args[i], params[i])) return null;
	}
	const copy = cloneNodeKeepSem(value);
	frameCopy(copy, new InlineFrame(fd.fnName, null, call.location.line), new HashMap<InlineFrame, InlineFrame>());
	return substituteParams(copy, params, target.args);
}

function leafValue(decl: Node): Node | null {
	const sym = decl.resolvedSym!;
	const fd = decl.data as FunctionDeclData;
	if (decl.paramSyms == null || fd.fnBody == null) return null;
	if (fd.fnFlags.indexOf("async") >= 0 || fd.fnFlags.indexOf("generator") >= 0 || fd.fnFlags.indexOf("gen:") >= 0) return null;
	if (hasFlag(sym, SymbolFlag.NoInline) || hasFlag(sym, SymbolFlag.CompileTime) || hostBound(sym)) return null;
	if (sym.symbolType == null || !isWordType(sym.symbolType.typeReturn)) return null;
	const stmts = extractBodyStmts(fd.fnBody);
	if (stmts.length != 1 || stmts[0].kind != NodeKind.ReturnStmt) return null;
	const value = (stmts[0].data as ReturnStmtData).argument;
	if (value == null || !pureOver(value, decl.paramSyms)) return null;
	return hasFlag(sym, SymbolFlag.Inline) || nodeCount(value) <= LEAF_NODE_LIMIT ? value : null;
}

function hostBound(sym: Symbol): boolean {
	const key = hostRoutineKey(sym);
	return sym.nativeName != "" || hasFlag(sym, SymbolFlag.ImportC) || (key != "" && lookupHost(key) != null);
}

function isWordType(t: Type | null): boolean {
	if (t == null) return false;
	return match (t.kind) {
		TypeKind.Int8 | TypeKind.Int16 | TypeKind.Int32 | TypeKind.Int64 | TypeKind.Uint8 | TypeKind.Uint16 | TypeKind.Uint32 | TypeKind.Uint64 => true,
		TypeKind.Float32 | TypeKind.Float64 | TypeKind.Number | TypeKind.Boolean | TypeKind.Char => true,
		_ => false,
	};
}

function pureOver(e: Node, params: Symbol[]): boolean {
	match (e.kind) {
		NodeKind.NumberLiteral | NodeKind.BooleanLiteral => { return isWordType(e.nodeType); },
		NodeKind.Identifier => { return e.resolvedSym != null && params.includes(e.resolvedSym); },
		NodeKind.BinaryExpr => {
			const b = e.data as BinaryExprData;
			return isWordType(e.nodeType) && !isAssignOp(b.operator) && !e.flags.has(NodeFlag.UserOp) && pureOver(b.left, params) && pureOver(b.right, params);
		},
		NodeKind.UnaryExpr => {
			const u = e.data as UnaryExprData;
			const op = u.unaryOp;
			return isWordType(e.nodeType) && (op == "-" || op == "+" || op == "!" || op == "~") && pureOver(u.operand, params);
		},
		NodeKind.ConditionalExpr => {
			const c = e.data as ConditionalExprData;
			return isWordType(e.nodeType) && pureOver(c.ternaryCondition, params) && pureOver(c.ternaryConsequent, params) && pureOver(c.ternaryAlternate, params);
		},
		NodeKind.TypeAssertion => {
			const checked = e.flags.has(NodeFlag.ObjCheck) || e.flags.has(NodeFlag.ConvCheck);
			return isWordType(e.nodeType) && !checked && pureOver((e.data as TypeAssertionData).asExpr, params);
		},
		NodeKind.HiddenStdConv | NodeKind.HiddenSubConv => {
			return isWordType(e.nodeType) && pureOver((e.data as HiddenStdConvData).convExpr, params);
		},
		NodeKind.MemberExpr => {
			const m = e.data as MemberExprData;
			const field = e.resolvedSym;
			if (m.isOptional || !isWordType(e.nodeType) || !declaresField(m.object.nodeType, m.property)) return false;
			if (field != null && (field.symbolKind != SymbolKind.Property || hasFlag(field, SymbolFlag.Static))) return false;
			return pureOver(m.object, params);
		},
		NodeKind.HiddenDeref => { return pureOver((e.data as HiddenDerefData).expr, params); },
		_ => { return false; },
	};
}

function declaresField(t: Type | null, name: string): boolean {
	let held = t;
	while (held != null && (held.kind == TypeKind.Ref || held.kind == TypeKind.Ptr || held.kind == TypeKind.Borrow || held.kind == TypeKind.Lent)) held = held.typeReturn;
	return held != null && held.kind == TypeKind.Struct && held.typeNames.includes(name);
}

function nodeCount(node: Node): int32 {
	let n: int32 = 1;
	forEachChild(node, (child: Node): void => { n += nodeCount(child); });
	return n;
}

function passesAsIs(arg: Node, param: Symbol): boolean {
	if (arg.kind == NodeKind.NumberLiteral || arg.kind == NodeKind.BooleanLiteral) return sameType(arg.nodeType, param.symbolType);
	const sym = arg.resolvedSym;
	if (arg.kind != NodeKind.Identifier || sym == null || hasFlag(sym, SymbolFlag.Global)) return false;
	if (sym.symbolKind != SymbolKind.Variable && sym.symbolKind != SymbolKind.Parameter) return false;
	return sameType(sym.symbolType, param.symbolType) && sameType(arg.nodeType, param.symbolType);
}

function substituteParams(node: Node, params: Symbol[], args: Node[]): Node {
	const at = node.kind == NodeKind.Identifier && node.resolvedSym != null ? params.indexOf(node.resolvedSym) : -1;
	if (at >= 0) return cloneNodeKeepSem(args[at]);
	mapChildren(node, (child: Node): Node => substituteParams(child, params, args));
	return node;
}

function frameCopy(node: Node, base: InlineFrame, rebased: HashMap<InlineFrame, InlineFrame>): void {
	node.inlineFrame = node.inlineFrame == null ? base : rebasedFrame(node.inlineFrame!, base, rebased);
	forEachChild(node, (child: Node): void => { frameCopy(child, base, rebased); });
}

function rebasedFrame(frame: InlineFrame, base: InlineFrame, rebased: HashMap<InlineFrame, InlineFrame>): InlineFrame {
	const known = rebased.get(frame);
	if (known != null) return known;
	const fresh = new InlineFrame(frame.name, frame.parent == null ? base : rebasedFrame(frame.parent!, base, rebased), frame.callLine);
	rebased.set(frame, fresh);
	return fresh;
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

test "a consumer body that returns without a value is expanded in place" {
	const prog = lowered(chainSrc + "function f(): void { for (const x of count(3)) { if (x == 1) return; } }");
	const stmts = getStmts(prog);
	assert countKind(stmts[stmts.length - 1], NodeKind.ForOfStmt) == 0;
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

test "a generator stored in a const that one for-of reads once is expanded at the read" {
	assert !stillForOf("function* g(): Iterator<int32> { yield 1; }\nconst it = g();\nfor (const x of it) { }");
	const prog = lowered("function* g(): Iterator<int32> { yield 1; }\nfunction f(c: boolean): void { const it = g(); if (c) { for (const x of it) { } } }");
	const stmts = getStmts(prog);
	assert countKind(stmts[stmts.length - 1], NodeKind.ForOfStmt) == 0;
}

test "a stored generator read twice, inside a loop, by a closure or through a let keeps the closure path" {
	assert stillForOf("function* g(): Iterator<int32> { yield 1; }\nconst it = g();\nfor (const x of it) { }\nfor (const y of it) { }");
	const looped = getStmts(lowered("function* g(): Iterator<int32> { yield 1; }\nconst it = g();\nfor (let k = 0; k < 2; k++) { for (const x of it) { } }"));
	assert countKind(looped[looped.length - 1], NodeKind.ForOfStmt) == 1;
	const closed = getStmts(lowered("function* g(): Iterator<int32> { yield 1; }\nconst it = g();\nconst f = (): void => { for (const x of it) { } };"));
	assert countKind(closed[closed.length - 1], NodeKind.ForOfStmt) == 1;
	assert stillForOf("function* g(): Iterator<int32> { yield 1; }\nlet it = g();\nfor (const x of it) { }");
}

const chainSrc = "function* count(n: int32): Iterator<int32> { for (let i = 0; i < n; i++) { yield i; } }\n";

test "a generator call passed as the source a generator iterates once is expanded in place too" {
	const prog = lowered(chainSrc + "function* doubled(it: Iterator<int32>): Iterator<int32> { for (const x of it) { yield x * 2; } }\nlet s = 0;\nfor (const y of doubled(count(3))) { s += y; }");
	const stmts = getStmts(prog);
	assert countKind(stmts[stmts.length - 1], NodeKind.ForOfStmt) == 0;
}

test "a generator passed as its own source is expanded at every level" {
	const prog = lowered(chainSrc + "function* doubled(it: Iterator<int32>): Iterator<int32> { for (const x of it) { yield x * 2; } }\nlet s = 0;\nfor (const y of doubled(doubled(doubled(count(3))))) { s += y; }");
	const stmts = getStmts(prog);
	assert countKind(stmts[stmts.length - 1], NodeKind.ForOfStmt) == 0;
}

test "a source read twice by the generator stays an iterator" {
	const prog = lowered(chainSrc + "function* firstThenRest(it: Iterator<int32>): Iterator<int32> { const f = it.next(); if (!f.done) yield f.value; for (const x of it) { yield x; } }\nfor (const y of firstThenRest(count(3))) { }");
	const stmts = getStmts(prog);
	assert countKind(stmts[stmts.length - 1], NodeKind.ForOfStmt) == 1;
}

test "a source the generator iterates inside a loop stays an iterator" {
	const prog = lowered(chainSrc + "function* again(it: Iterator<int32>): Iterator<int32> { for (let k = 0; k < 2; k++) { for (const x of it) { yield x; } } }\nfor (const y of again(count(3))) { }");
	const stmts = getStmts(prog);
	assert countKind(stmts[stmts.length - 1], NodeKind.ForOfStmt) == 1;
}

const sumSrc = chainSrc + "function total(it: Iterator<int32>): int32 { let t = 0; for (const x of it) { t += x; } return t; }\n";

function lastStmtCalls(src: string): int32 {
	const stmts = getStmts(lowered(src));
	return countKind(stmts[stmts.length - 1], NodeKind.CallExpr);
}

test "a consumer of a generator call declared with its result is expanded in place" {
	const stmts = getStmts(lowered(sumSrc + "function f(): int32 { const s = total(count(3)); return s; }"));
	const body = (stmts[stmts.length - 1].data as FunctionDeclData).fnBody;
	assert countKind(body, NodeKind.CallExpr) == 0;
	assert countKind(body, NodeKind.ForOfStmt) == 0;
}

test "a consumer of a generator call is expanded in place when returned or assigned" {
	assert lastStmtCalls(sumSrc + "function f(): int32 { return total(count(3)); }") == 0;
	assert lastStmtCalls(sumSrc + "function f(): int32 { let s = 0; s = total(count(3)); return s; }") == 0;
}

test "a consumer assigned with a compound operator is expanded in place" {
	assert lastStmtCalls(sumSrc + "function f(): int32 { let s = 1; s += total(count(3)); return s; }") == 0;
	assert lastStmtCalls(sumSrc + "function f(): int32 { let s = 1; s *= total(count(3)); return s; }") == 0;
}

test "a consumer under a cast as a statement is expanded in place and keeps its cast" {
	const stmts = getStmts(lowered(sumSrc + "function f(): void { total(count(3)) as int8; }"));
	const body = (stmts[stmts.length - 1].data as FunctionDeclData).fnBody;
	assert countKind(body, NodeKind.CallExpr) == 0;
	assert countKind(body, NodeKind.TypeAssertion) == 1;
}

test "a consumer of an iterator stored in a const read once is expanded in place" {
	assert lastStmtCalls(sumSrc + "function f(): int32 { const it = count(3); return total(it); }") == 0;
	assert lastStmtCalls(sumSrc + "function f(): int32 { const it = count(3); const s = total(it); return s; }") == 0;
	const doubled = "function* doubled(it: Iterator<int32>): Iterator<int32> { for (const x of it) { yield x * 2; } }\n";
	assert lastStmtCalls(sumSrc + doubled + "function f(): int32 { const a = count(3); const b = doubled(a); return total(b); }") == 0;
}

test "a consumer of an iterator stored in a const read twice stays a call" {
	assert lastStmtCalls(sumSrc + "function f(): int32 { const it = count(3); const a = total(it); return a + total(it); }") == 3;
}

test "a consumer call that is an operand of a larger expression is expanded before it" {
	const stmts = getStmts(lowered(sumSrc + "function f(): int32 { return 1 + total(count(3)); }"));
	const body = (stmts[stmts.length - 1].data as FunctionDeclData).fnBody;
	assert countKind(body, NodeKind.CallExpr) == 0;
	assert countKind(body, NodeKind.ForOfStmt) == 0;
}

test "a consumer call after an operand whose effect no temp holds stays a call" {
	assert lastStmtCalls(sumSrc + "function g(): int32 { return 1; }\nfunction f(c: boolean): int32 { return (c ? g() : 0) + total(count(3)); }") == 3;
}

const fwdSrc = chainSrc
	+ "function shut(it: Iterator<int32>): void { if (it.return != null) it.return(); }\n"
	+ "function* firstN(it: Iterator<int32>, n: int32): Iterator<int32> { for (const x of it) { yield x; } }\n";

function forOfsLeft(src: string): int32 {
	const stmts = getStmts(lowered(fwdSrc + src));
	return countKind(stmts[stmts.length - 1], NodeKind.ForOfStmt);
}

test "a forwarder that touches its source only on a throwing path is expanded down to its generator" {
	const fwd = "function firsts(it: Iterator<int32>, n: int32): Iterator<int32> { if (n < 0) { shut(it); throw new Error(\"neg\"); } return firstN(it, n); }\n";
	assert forOfsLeft(fwd + "for (const x of firsts(count(9), 3)) { }") == 0;
}

test "a forwarder that touches its source on the path it forwards keeps the source an iterator" {
	const fwd = "function firsts(it: Iterator<int32>, n: int32): Iterator<int32> { shut(it); return firstN(it, n); }\n";
	assert forOfsLeft(fwd + "for (const x of firsts(count(9), 3)) { }") == 1;
}

const staticSrc = sumSrc
	+ "struct Steps { }\n"
	+ "function* stepsLazy(n: int32): Iterator<int32> { for (let i = 0; i < n; i++) { yield i; } }\n"
	+ "function upTo(this typeof Steps, n: int32): Iterator<int32> { if (n < 0) { throw new Error(\"neg\"); } return stepsLazy(n); }\n"
	+ "function* evens(this typeof Steps, n: int32): Iterator<int32> { for (let i = 0; i < n; i += 2) { yield i; } }\n";

function staticForOfsLeft(src: string, js: boolean): int32 {
	const parsed = parseInput(staticSrc + src);
	if (!parsed.ok) throw new Error(parsed.error);
	if (js) checkProgramJs(parsed.value);
	else checkProgram(parsed.value);
	const stmts = getStmts(lowerIterInline(parsed.value, js ? makeJsCtx() : makeCtx()));
	return countKind(stmts[stmts.length - 1], NodeKind.ForOfStmt);
}

test "a for-of over a static extension generator or forwarder is expanded in place" {
	for (const js of [false, true]) {
		assert staticForOfsLeft("for (const x of Steps.evens(6)) { }", js) == 0;
		assert staticForOfsLeft("for (const x of Steps.upTo(3)) { }", js) == 0;
	}
}

test "a consumer of a static extension call is expanded in place" {
	assert lastStmtCalls(staticSrc + "function f(): int32 { return total(Steps.upTo(3)); }") == 0;
	assert lastStmtCalls(staticSrc + "function f(): int32 { const s = total(Steps.evens(6)); return s; }") == 0;
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
