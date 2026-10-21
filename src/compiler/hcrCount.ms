import { Type, TypeKind } from "../ast/node";
import { CEmissionFacts, CTypeInfoDemand, TypeInfoKind } from "../codegen/c/context";
import { objectTypeInfoKey } from "../codegen/c/types";
import { sameNominal } from "../checker/compat";
import { hasGenericParams } from "../checker/types";
import { HcrIndirectModule, HcrTypeLayout } from "../transform/native/hcrIndirect";

const MAX_BASE_DEPTH = 64;

function bodyOf(t: Type): Type;
function bodyOf(t: Readonly<Type>): Readonly<Type>;
function bodyOf(t: Readonly<Type>): Readonly<Type> {
	let body = t;
	while (body.kind == TypeKind.Ref && body.typeReturn != null) body = body.typeReturn;
	return body;
}

function ownNames(t: Readonly<Type>): Readonly<string[] | null> {
	if (t.kind == TypeKind.Struct) return t.typeNames;
	if (t.kind != TypeKind.GenericInstance || t.typeExtra == null) return null;
	const declared = bodyOf(t.typeExtra);
	return declared.kind == TypeKind.Struct ? declared.typeNames : null;
}

function parentNamesOf(t: Readonly<Type>): Readonly<Type | null> {
	if (t.kind == TypeKind.Struct) return t.typeExtra;
	if (t.kind != TypeKind.GenericInstance || t.typeExtra == null) return null;
	const declared = bodyOf(t.typeExtra);
	return declared.kind == TypeKind.Struct ? declared.typeExtra : null;
}

function fieldNames(t: Readonly<Type>): string[] | null {
	const chain: Readonly<string[]>[] = [];
	let cur: Readonly<Type | null> = bodyOf(t);
	while (cur != null) {
		const names = ownNames(cur);
		if (names == null || chain.length >= MAX_BASE_DEPTH) return null;
		chain.push(names);
		const parent = parentNamesOf(cur);
		cur = parent == null ? null : bodyOf(parent);
	}
	const all: string[] = [];
	for (let i = chain.length - 1; i >= 0; i -= 1) {
		for (const name of chain[i]) all.push(name);
	}
	return all;
}

function isLeadingPrefix(prefix: string[], names: string[]): boolean {
	if (names.length < prefix.length) return false;
	for (let i = 0; i < prefix.length; i += 1) {
		if (prefix[i] != names[i]) return false;
	}
	return true;
}

function derivesFrom(other: Readonly<CTypeInfoDemand>, key: string, facts: Readonly<CEmissionFacts>): boolean {
	let at = other.baseKey;
	for (let depth = 0; at != "" && depth < MAX_BASE_DEPTH; depth += 1) {
		if (at == key) return true;
		const next = facts.typeInfos.readonlyGet(at);
		if (next == null) return false;
		at = next.baseKey;
	}
	return false;
}

function holdsVariant(union: Readonly<Type>, subject: Type): boolean {
	for (const child of union.typeChildren) {
		if (child != null && sameNominal(bodyOf(child), subject)) return true;
	}
	return false;
}

function viewsAs(other: Readonly<CTypeInfoDemand>, subject: Type, own: string[], key: string, facts: Readonly<CEmissionFacts>): boolean {
	if (derivesFrom(other, key, facts)) return false;
	if (other.subject.kind == TypeKind.Union) return holdsVariant(other.subject, subject);
	const theirs = fieldNames(other.subject);
	return theirs == null || isLeadingPrefix(own, theirs);
}

function moduleIdOf(modulePath: string, modules: HcrIndirectModule[]): string {
	for (const module of modules) {
		if (module.modulePath == modulePath) return module.moduleId;
	}
	return "";
}

function countSpec(layout: HcrTypeLayout, module: HcrIndirectModule, modules: HcrIndirectModule[], facts: Readonly<CEmissionFacts>, counted: boolean): string {
	if (!counted) return "!is not counted under this --gc mode";
	if (layout.byValue) return "!is held by value";
	const subject = bodyOf(layout.subject);
	if (hasGenericParams(subject)) return "!is generic, and the counter does not cover its instances";
	const own = fieldNames(subject);
	if (own == null) return "!has a layout the counter cannot compare with other types";
	const key = objectTypeInfoKey(subject);
	const entries: string[] = [];
	for (const other of facts.typeInfoOrder) {
		if (other.kind != TypeInfoKind.Object) continue;
		const itself = other.key == key;
		if (!itself && !viewsAs(other, subject, own, key, facts)) continue;
		const owner = moduleIdOf(other.owner, modules);
		if (owner == "") {
			if (itself) return "!is allocated outside the HCR registry";
			return `!may also be viewed through '${other.subject.typeName}', which is outside the HCR registry`;
		}
		entries.push(`${owner}:${other.cName}`);
	}
	return entries.join(",");
}

export function hcrTypeCounts(module: HcrIndirectModule, modules: HcrIndirectModule[], facts: Readonly<CEmissionFacts>, counted: boolean): string[] {
	const counts: string[] = [];
	for (const layout of module.typeLayouts) {
		counts.push(layout.name);
		counts.push(countSpec(layout, module, modules, facts, counted));
	}
	return counts;
}
