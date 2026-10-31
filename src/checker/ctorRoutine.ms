import { Node, NodeKind, ClassDeclData, ActorDeclData, DecoratedDeclData, ConstructorDeclData, Symbol, SymbolKind, Type, TypeKind } from "../ast/node";
import { CheckerContext, addError, newSym } from "./context";
import { RoutineFlag, SymbolFlag, classDeclNodeOf, hasFlag, initFnName, routineFlagSet, setFlag } from "./symbol";
import { createFunction, setMinArity, voidType } from "./types";
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
	const routine = newCtorRoutine(ctx, owner, ownerName, thisType, userTypes, userNames, declNode, defaults);
	registerCtorRoutine(owner, routine);
	return routine;
}

export function isCtorSignature(member: Node): boolean {
	return member.kind == NodeKind.ConstructorDecl && routineFlagSet((member.data as ConstructorDeclData).ctorFlags).has(RoutineFlag.Overload);
}

export function mintCtorSignature(ctx: CheckerContext, owner: Symbol, ownerName: string, thisType: Type, userTypes: Type[], userNames: string[], declNode: Node, defaults: Node[]): Symbol {
	const routine = newCtorRoutine(ctx, owner, ownerName, thisType, userTypes, userNames, declNode, defaults);
	setFlag(routine, SymbolFlag.OverloadSig);
	setMinArity(routine.symbolType, requiredCtorArgs(userTypes, defaults) + 1);
	return routine;
}

function newCtorRoutine(ctx: CheckerContext, owner: Symbol, ownerName: string, thisType: Type, userTypes: Type[], userNames: string[], declNode: Node | null, defaults: Node[]): Symbol {
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
	return routine;
}

// The implementation's `overloads` list holds the class's constructor signatures in declaration
// order, the set a `new` ranks; the implementation itself is never a candidate.
export function linkCtorSignatures(ctx: CheckerContext, owner: Symbol, body: Node[]): void {
	const members: Node[] = [];
	for (const raw of body) {
		const member = raw.kind == NodeKind.DecoratedDecl ? (raw.data as DecoratedDeclData).decoratedNode : raw;
		if (member.kind == NodeKind.ConstructorDecl) members.push(member);
	}
	let impl: Symbol | null = null;
	let implCount = 0;
	let last: Node | null = null;
	for (const m of members) {
		if (!isCtorSignature(m)) { impl = m.resolvedSym; implCount += 1; } else last = m;
	}
	if (last == null) return;
	if (impl == null || implCount > 1) {
		const at = implCount > 1 ? members.filter((m: Node): boolean => !isCtorSignature(m))[1] : last;
		if (impl == null && last.resolvedSym != null) registerCtorRoutine(owner, last.resolvedSym);
		addError(ctx, implCount > 1 ? `Overloaded constructor of '${owner.name}' has more than one implementation: only one definition may have a body` : `Overloaded constructor of '${owner.name}' has no implementation: one definition must have a body`, at.location.line, at.location.column);
		return;
	}
	for (const m of members) {
		if (!isCtorSignature(m) || m.resolvedSym == null) continue;
		impl.overloads.push(m.resolvedSym);
		m.resolvedSym.overloadIdx = impl.overloads.length;
	}
}

export function ctorSignaturesOf(routine: Symbol | null): Symbol[] {
	if (routine == null) return [];
	return routine.overloads.filter((s: Symbol): boolean => hasFlag(s, SymbolFlag.OverloadSig));
}

function declaredCtorRoutine(owner: Symbol): Symbol | null {
	const decl = classDeclNodeOf(owner);
	if (decl == null) return null;
	const body = decl.kind == NodeKind.ActorDecl ? (decl.data as ActorDeclData).actorBody : (decl.data as ClassDeclData).classBody;
	for (const raw of body) {
		const member = raw.kind == NodeKind.DecoratedDecl ? (raw.data as DecoratedDeclData).decoratedNode : raw;
		if (member.kind == NodeKind.ConstructorDecl && !isCtorSignature(member)) return member.resolvedSym;
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

export function requiredCtorArgs(formals: Type[], defaults: Node[] | null): int32 {
	let required: int32 = 0;
	for (let i = 0; i < formals.length; i += 1) {
		const hasDefault = defaults != null && i < defaults.length && defaults[i] != null;
		if (!hasDefault && formals[i].kind != TypeKind.Varargs) required = i + 1;
	}
	return required;
}
