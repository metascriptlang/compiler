import { Node, NodeKind, ClassDeclData, ActorDeclData, DecoratedDeclData, Symbol, SymbolKind, Type, TypeKind } from "../ast/node";
import { CheckerContext, newSym } from "./context";
import { SymbolFlag, classDeclNodeOf, hasFlag, initFnName } from "./symbol";
import { createFunction, voidType } from "./types";
import { pickBodyCtx } from "./instantiate";

export interface CtorRow {
	owner: Symbol;
	routine: Symbol;
}

let _capture: CtorRow[] | null = null;

export function resetCtorRoutines(): void {
	_capture = null;
}

export function startCtorCapture(): CtorRow[] | null {
	const outer = _capture;
	_capture = [];
	return outer;
}

export function endCtorCapture(outer: CtorRow[] | null): CtorRow[] {
	const captured = _capture;
	_capture = outer;
	return captured!;
}

export function replayCtorRoutines(rows: CtorRow[]): void {
	for (const row of rows) {
		if (row.owner.ctorRoutine == null) registerCtorRoutine(row.owner, row.routine);
	}
}

function registerCtorRoutine(owner: Symbol, routine: Symbol): void {
	if (_capture != null) _capture.push({ owner, routine });
	owner.ctorRoutine = routine;
}

export function mintCtorRoutine(ctx: CheckerContext, owner: Symbol, ownerName: string, thisType: Type, userTypes: Type[], userNames: string[], declNode: Node | null, defaults: Node[]): Symbol {
	const types: Type[] = [thisType];
	const names: string[] = ["this"];
	for (const t of userTypes) types.push(t);
	for (const n of userNames) names.push(n);
	const routine = newSym(ctx, SymbolKind.Function, initFnName(ownerName), createFunction(types, names, voidType()));
	routine.modulePath = owner.modulePath;
	if (declNode != null) {
		routine.declNode = declNode;
		routine.location = declNode.location;
		declNode.resolvedSym = routine;
	}
	routine.defaultParams = defaults;
	registerCtorRoutine(owner, routine);
	return routine;
}

function declaredCtorRoutine(owner: Symbol): Symbol | null {
	const decl = classDeclNodeOf(owner);
	if (decl == null) return null;
	const body = decl.kind == NodeKind.ActorDecl ? (decl.data as ActorDeclData).actorBody : (decl.data as ClassDeclData).classBody;
	for (const raw of body) {
		const member = raw.kind == NodeKind.DecoratedDecl ? (raw.data as DecoratedDeclData).decoratedNode : raw;
		if (member.kind == NodeKind.ConstructorDecl) return member.resolvedSym;
	}
	return null;
}

export function ctorRoutineOf(owner: Symbol | null): Symbol | null {
	if (owner == null) return null;
	if (owner.ctorRoutine != null) return owner.ctorRoutine;
	return declaredCtorRoutine(owner);
}

export function ctorRoutineFor(ctx: CheckerContext, owner: Symbol): Symbol | null {
	const known = ctorRoutineOf(owner);
	if (known != null) return known;
	if (owner.symbolKind != SymbolKind.Class && owner.symbolKind != SymbolKind.Actor) return null;
	if (hasFlag(owner, SymbolFlag.HasConstructor)) throw new Error(`internal: class '${owner.name}' has a written constructor but no routine symbol`);
	if (owner.instantiatedFrom == null) return mintCtorRoutine(pickBodyCtx(owner.modulePath, ctx, owner), owner, owner.name, owner.symbolType, [], [], null, []);
	const host = ctx.instantiatingCtx != null ? ctx.instantiatingCtx : ctx;
	const routine = mintCtorRoutine(host, owner, owner.name, owner.symbolType, [], [], null, []);
	routine.instantiatedFrom = ctorRoutineOf(owner.instantiatedFrom);
	return routine;
}

export function ctorFormalTypes(routine: Symbol | null): Type[] | null {
	if (routine == null || routine.symbolType == null || routine.symbolType.kind != TypeKind.Function) return null;
	return routine.symbolType.typeChildren.slice(1);
}
