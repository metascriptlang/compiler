import { env } from "std/process";
import {
	Node, NodeKind, NodeFlag,
	FunctionDeclData, MethodDeclData, FunctionExprData, ArrowFunctionData,
	MemberExprData, BinaryExprData, SwitchStmtData, CallExprData,
} from "../ast/node";
import { forEachChild } from "../ast/visitor";
import { RoutineFlag, routineFlagSet } from "../checker/symbol";
import { routineKindFlag } from "../checker/context";
import { TransformContext, ModuleFact, reportTransformError } from "./context";
import { isRuntimeProcSym } from "./util";
import { sharedProbe } from "./coercion/optionalChain";

const NO_FACTS = 0 as BitSet<ModuleFact>;

function routineFacts(flags: string): BitSet<ModuleFact> {
	if (flags == "") return NO_FACTS;
	const set = routineFlagSet(flags);
	const kind = routineKindFlag(flags);
	let facts = NO_FACTS;
	if (set.has(RoutineFlag.Async) || kind == "async" || kind == "async_generator") facts = facts.incl(ModuleFact.Async);
	if (set.has(RoutineFlag.Generator)) facts = facts.incl(ModuleFact.Generator);
	return facts;
}

function isSpawnCall(node: Node): boolean {
	const sym = node.resolvedSym != null ? node.resolvedSym : (node.data as CallExprData).callee.resolvedSym;
	return sym != null && (sym.builtinKind == "PromiseSpawn" || isRuntimeProcSym(sym, "msSpawn"));
}

function factIf(holds: boolean, f: ModuleFact): BitSet<ModuleFact> {
	return holds ? NO_FACTS.incl(f) : NO_FACTS;
}

export function factsOf(node: Node): BitSet<ModuleFact> {
	const own = match (node.kind) {
		NodeKind.FunctionDecl => routineFacts((node.data as FunctionDeclData).fnFlags),
		NodeKind.MethodDecl => routineFacts((node.data as MethodDeclData).methodFlags),
		NodeKind.FunctionExpr => routineFacts((node.data as FunctionExprData).funcExprFlags),
		NodeKind.ArrowFunction => routineFacts((node.data as ArrowFunctionData).arrowFlags),
		NodeKind.AwaitExpr => NO_FACTS.incl(ModuleFact.Await),
		NodeKind.CallExpr => factIf(isSpawnCall(node), ModuleFact.Spawn),
		NodeKind.DeferStmt => NO_FACTS.incl(ModuleFact.Defer),
		NodeKind.MemberExpr => factIf((node.data as MemberExprData).isOptional, ModuleFact.OptionalChain),
		NodeKind.ConditionalExpr => factIf(sharedProbe(node) != null, ModuleFact.OptionalChain),
		NodeKind.BinaryExpr => factIf((node.data as BinaryExprData).operator == "??", ModuleFact.Nullish),
		NodeKind.SpreadExpr => NO_FACTS.incl(ModuleFact.Spread),
		NodeKind.SwitchStmt => factIf(!(node.data as SwitchStmtData).switchLowered, ModuleFact.Switch),
		_ => NO_FACTS,
	};
	return node.flags.has(NodeFlag.WasAsync) ? own.incl(ModuleFact.Async) : own;
}

export function collectFacts(node: Node | null): BitSet<ModuleFact> {
	if (node == null) return NO_FACTS;
	let facts = factsOf(node);
	forEachChild(node, (child: Node): void => { facts = facts.union(collectFacts(child)); });
	return facts;
}

let factsCheckOn = env.get("MSC_FACTS_CHECK") == "1";
let factsMisses: int32 = 0;

export function factsCheckEnabled(): boolean {
	return factsCheckOn;
}

export function factsCheckEnable(on: boolean): void {
	factsCheckOn = on;
	factsMisses = 0;
}

export function factsCheckMisses(): int32 {
	return factsMisses;
}

export function checkFactsAfter(program: Node, ctx: TransformContext, pass: string): void {
	if (!factsCheckOn || !ctx.factsCollected) return;
	const missing = collectFacts(program).difference(ctx.facts);
	if (missing.isEmpty()) return;
	factsMisses += 1;
	reportTransformError(ctx, `internal: after ${pass} the module holds ${missing.toString()} but its facts lack it, so a gated pass would skip it (MSC_FACTS_CHECK)`, program.location);
	ctx.facts = ctx.facts.union(missing);
}
