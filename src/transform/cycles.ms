// canFormAcycle — reference parity: types.nim canFormAcycleAux + cyclicType
// (liftdestructors.nim:695-699). Answers "can a reference cycle pass THROUGH
// cells of this type", not "does this type transitively contain a ref".
// A walk is cyclic only when it returns to the origin through >=1 Ref hop,
// or reaches a closure (reference tyProc ccClosure arm).
//
// Identity for the back-edge check and the recursion guard is the resolved
// type NAME (typeName | anonTypeName | mangleMonoName) — the MS-native ItemId
// under per-module type copies (NIM-REF import-resolution divergence).
//
// Intermediate results depend on the walk origin and MUST NOT be memoized;
// only entry-level answers go to the caller-owned caches (reference: Nim uses
// a fresh IntSet marker per query and no cache at all).
//
// Unknown pointee (Ref with null typeReturn) is conservatively cyclic.
// The reference non-final rule (types.nim:436-438) is implemented via the
// OpenClass bit on the Struct arm below — a class that is extended is cyclic.

import { Type, TypeKind, TypeFlag } from "../ast/node";
import { NameSet, createNameSet, nameSetAdd, nameSetContains } from "./context";
import { isAwaitable, unwrapRefNullUnion, isUnresolvedType } from "../checker/types";
import { anonTypeName, isAnonTypeName } from "../codegen/c/types";
import { mangleMonoName } from "../monomorphize/registry";

function typeIdentity(t: Type): string {
	if (t.kind === TypeKind.GenericInstance) {
		if (t.typeName !== "") return mangleMonoName(t.typeName, t.typeChildren);
		return "";
	}
	if (t.typeName !== "" && !isAnonTypeName(t.typeName)) return t.typeName;
	if (t.typeNames.length > 0) return anonTypeName(t);
	return "";
}

function cfaAux(t: Type | null, origKey: string, withRef: boolean, marker: NameSet): boolean {
	if (t === null) return false;
	return match (t.kind) {
		TypeKind.Ref => {
			if (t.typeReturn === null) return true;
			return cfaAux(t.typeReturn, origKey, true, marker);
		},
		TypeKind.Function => true,
		TypeKind.Struct => {
			// Non-final rule (types.nim:436-438 `if tfFinal notin t.flags: result = true`):
			// a class that is extended (OpenClass bit, stamped in resolveClass) can be
			// subclassed into a back-edge, so it can form a cycle independent of its
			// own declared fields. Independent of the typeExtra walk below (that covers
			// field inheritance; BOTH apply).
			if ((t.typeFlags & TypeFlag.OpenClass) !== 0) return true;
			const key = typeIdentity(t);
			if (withRef && key !== "" && key === origKey) return true;
			if (key !== "") {
				if (nameSetContains(marker, key)) return false;
				nameSetAdd(marker, key);
			}
			if (t.typeExtra !== null && cfaAux(t.typeExtra, origKey, withRef, marker)) return true;
			for (const child of t.typeChildren) {
				if (cfaAux(child, origKey, withRef, marker)) return true;
			}
			return false;
		},
		TypeKind.Union => {
			const key = typeIdentity(t);
			if (withRef && key !== "" && key === origKey) return true;
			if (key !== "") {
				if (nameSetContains(marker, key)) return false;
				nameSetAdd(marker, key);
			}
			for (const variant of t.typeChildren) {
				if (cfaAux(variant, origKey, withRef, marker)) return true;
			}
			return false;
		},
		TypeKind.Tuple => {
			for (const child of t.typeChildren) {
				if (cfaAux(child, origKey, withRef, marker)) return true;
			}
			return false;
		},
		TypeKind.GenericInstance => {
			if (isAwaitable(t)) return false;
			const key = typeIdentity(t);
			if (withRef && key !== "" && key === origKey) return true;
			if (key !== "") {
				if (nameSetContains(marker, key)) return false;
				nameSetAdd(marker, key);
			}
			return cfaAux(t.typeReturn, origKey, withRef, marker);
		},
		TypeKind.Array | TypeKind.SizedArray | TypeKind.Span => cfaAux(t.typeReturn, origKey, withRef, marker),
		TypeKind.Varargs => {
			if (t.typeChildren.length > 0) return cfaAux(t.typeChildren[0], origKey, withRef, marker);
			return false;
		},
		TypeKind.Distinct | TypeKind.Alias | TypeKind.Var | TypeKind.Sink | TypeKind.Lent | TypeKind.Result => cfaAux(t.typeReturn, origKey, withRef, marker),
		_ => false,
	};
}

export function canFormAcycle(t: Type | null, cyclicCache: NameSet, acyclicCache: NameSet): boolean {
	if (t === null) return false;
	let subject: Type | null = t;
	if (subject.kind === TypeKind.Union) {
		const refInner = unwrapRefNullUnion(subject);
		if (refInner !== null) subject = refInner;
	}
	if (subject.kind === TypeKind.Function) return true;
	if (subject.kind === TypeKind.Ptr || isUnresolvedType(subject)) return false;
	if (subject.kind === TypeKind.Ref) {
		if (subject.typeReturn === null) return true;
		subject = subject.typeReturn;
	}
	if (subject === null) return false;
	const key = typeIdentity(subject);
	if (key !== "") {
		if (nameSetContains(cyclicCache, key)) return true;
		if (nameSetContains(acyclicCache, key)) return false;
	}
	const marker = createNameSet();
	const result = cfaAux(subject, key, false, marker);
	if (key !== "") {
		if (result) { nameSetAdd(cyclicCache, key); } else { nameSetAdd(acyclicCache, key); }
	}
	return result;
}
