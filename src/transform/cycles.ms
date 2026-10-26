// canFormAcycle — reference parity: types.nim canFormAcycleAux + cyclicType
// (liftdestructors.nim:695-699). Answers "can a reference cycle pass THROUGH
// cells of this type", not "does this type transitively contain a ref".
// A walk is cyclic only when it returns to the origin through >=1 Ref hop,
// or reaches a closure (reference tyProc ccClosure arm).
//
// Identity for the back-edge check and the recursion guard is the resolved
// type NAME (typeName | anonTypeName | monoInstanceName; typeKey for an array) —
// the MS-native ItemId under per-module type copies (NIM-REF CK-19).
//
// Intermediate results depend on the walk origin and MUST NOT be memoized;
// only entry-level answers go to the caller-owned caches (reference: Nim uses
// a fresh IntSet marker per query and no cache at all).
//
// Unknown pointee (Ref with null typeReturn) is conservatively cyclic.
// The reference non-final rule (types.nim:433-435) is implemented via the
// OpenClass bit on the Struct arm below — a class that is extended is cyclic. An interface
// or unnamed record is open the same way, but only to the object types the checker accepted
// behind it, so a hierarchy whose implementers cannot reach back and cannot form a cycle
// themselves stays acyclic.

import { Type, TypeKind, TypeFlag, SymbolKind } from "../ast/node";
import { NameSet, createNameSet, nameSetAdd, nameSetContains } from "./context";
import { isAwaitable, unwrapRefNullUnion, isUnknownType, genericParamsOf, instantiateGenericBody, nominalTypeKey, countedEvictElement, isAtomicRef, heldBeyond, hasGenericParams, hasTypeIdentity } from "../checker/types";
import { anonTypeName, isAnonTypeName, typeKey } from "../codegen/c/types";
import { monoInstanceName } from "../monomorphize/registry";

function typeIdentity(t: Type): string {
	if (t.kind == TypeKind.GenericInstance) {
		if (t.typeName != "") return monoInstanceName(t);
		return "";
	}
	if (t.kind == TypeKind.Array || t.kind == TypeKind.SizedArray || t.kind == TypeKind.Span) return typeKey(t);
	if (t.typeName != "" && !isAnonTypeName(t.typeName)) {
		if (t.kind != TypeKind.Struct && t.kind != TypeKind.Union) return t.typeName;
		return t.sym != null && t.sym.instantiatedFrom != null ? t.typeName : nominalTypeKey(t);
	}
	if (t.typeNames.length > 0) return anonTypeName(t);
	return "";
}

function cfaAux(t: Type | null, origKey: string, withRef: boolean, marker: NameSet): boolean {
	if (t == null) return false;
	return match (t.kind) {
		TypeKind.Ref => {
			if (t.typeReturn == null) return true;
			return cfaAux(t.typeReturn, origKey, true, marker);
		},
		TypeKind.Function | TypeKind.Unknown => true,
		TypeKind.Struct => {
			// Non-final rule (types.nim:436-438 `if tfFinal notin t.flags: result = true`):
			// a class that is extended (OpenClass bit, stamped in resolveClass) can be
			// subclassed into a back-edge, so it can form a cycle independent of its
			// own declared fields. Independent of the typeExtra walk below (that covers
			// field inheritance; BOTH apply).
			if (t.typeFlags.has(TypeFlag.Acyclic)) return false;
			if (t.typeFlags.has(TypeFlag.OpenClass)) return true;
			const key = typeIdentity(t);
			if (withRef && key != "" && key == origKey) return true;
			if (key != "") {
				if (nameSetContains(marker, key)) return false;
				nameSetAdd(marker, key);
			}
			return cfaStructFields(t, origKey, withRef, marker);
		},
		TypeKind.Union => {
			const key = typeIdentity(t);
			if (withRef && key != "" && key == origKey) return true;
			if (key != "") {
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
			if (t.typeReturn == null) {
				const params = genericParamsOf(t);
				if (params != "") instantiateGenericBody(t, params);
			}
			const key = typeIdentity(t);
			if (withRef && key != "" && key == origKey) return true;
			if (key != "") {
				if (nameSetContains(marker, key)) return false;
				nameSetAdd(marker, key);
			}
			return cfaInstanceBody(t.typeReturn, origKey, withRef, marker);
		},
		TypeKind.Array | TypeKind.SizedArray | TypeKind.Span => {
			const key = typeIdentity(t);
			if (withRef && key == origKey) return true;
			if (nameSetContains(marker, key)) return false;
			nameSetAdd(marker, key);
			return cfaAux(t.typeReturn, origKey, withRef, marker);
		},
		TypeKind.Varargs => {
			if (t.typeChildren.length > 0) return cfaAux(t.typeChildren[0], origKey, withRef, marker);
			return false;
		},
		TypeKind.Distinct | TypeKind.Alias | TypeKind.Var | TypeKind.Sink | TypeKind.Lent | TypeKind.Result => cfaAux(t.typeReturn, origKey, withRef, marker),
		_ => false,
	};
}

function cfaStructFields(t: Type, origKey: string, withRef: boolean, marker: NameSet): boolean {
	if (t.typeExtra != null && cfaAux(t.typeExtra, origKey, withRef, marker)) return true;
	for (const child of t.typeChildren) {
		if (cfaAux(child, origKey, withRef, marker)) return true;
	}
	return cfaHeldBeyond(t, origKey, withRef, marker);
}

// An interface or unnamed record stands for every object type the checker accepted behind
// it (noteHeldBeyond); a cycle can run through any of them. An implementer with generic
// parameters, or no identity to key a walk by, has fields no walk can see, so it counts as closing one.
function cfaHeldBeyond(t: Type, origKey: string, withRef: boolean, marker: NameSet): boolean {
	for (const held of heldBeyond(t)) {
		if (hasGenericParams(held) || !hasTypeIdentity(held) || cfaAux(held, origKey, withRef, marker)) return true;
	}
	return false;
}

function cfaInstanceBody(body: Type | null, origKey: string, withRef: boolean, marker: NameSet): boolean {
	if (body == null) return false;
	if (body.kind == TypeKind.Ref) {
		if (body.typeReturn == null) return true;
		return cfaInstanceBody(body.typeReturn, origKey, true, marker);
	}
	if (body.kind == TypeKind.Struct) {
		if (body.typeFlags.has(TypeFlag.Acyclic)) return false;
		if (body.typeFlags.has(TypeFlag.OpenClass)) return true;
		return cfaStructFields(body, origKey, withRef, marker);
	}
	if (body.kind == TypeKind.Union) {
		for (const variant of body.typeChildren) {
			if (cfaAux(variant, origKey, withRef, marker)) return true;
		}
		return false;
	}
	return cfaAux(body, origKey, withRef, marker);
}

export function canFormAcycle(t: Type | null, cyclicCache: NameSet, acyclicCache: NameSet): boolean {
	if (t == null) return false;
	let subject: Type | null = t;
	if (subject.kind == TypeKind.Union) {
		const refInner = unwrapRefNullUnion(subject);
		if (refInner != null) subject = refInner;
	}
	if (subject.kind == TypeKind.Function || isUnknownType(subject)) return true;
	if (subject.kind == TypeKind.Ptr) return false;
	if (subject.kind == TypeKind.Ref) {
		if (subject.typeReturn == null) return true;
		subject = subject.typeReturn;
	}
	if (subject == null) return false;
	if (subject.typeFlags.has(TypeFlag.Acyclic)) return false;
	const key = typeIdentity(subject);
	if (key != "") {
		if (nameSetContains(cyclicCache, key)) return true;
		if (nameSetContains(acyclicCache, key)) return false;
	}
	const marker = createNameSet();
	const result = cfaAux(subject, key, false, marker) || implementerCanFormAcycle(subject, cyclicCache);
	if (key != "") {
		if (result) { nameSetAdd(cyclicCache, key); } else { nameSetAdd(acyclicCache, key); }
	}
	return result;
}

// A cell typed by an interface is a cell of one of the types held beyond it, so it can form a
// cycle whenever one of them can, even when no path returns to the interface itself.
function implementerCanFormAcycle(t: Type, cyclicCache: NameSet): boolean {
	const seen = createNameSet();
	const slots: Type[] = [t];
	while (slots.length > 0) {
		const slot = slots.pop()!;
		const inst = slot.kind == TypeKind.GenericInstance ? instanceBody(slot) : slot;
		const body = inst != null && inst.kind == TypeKind.Ref ? inst.typeReturn : inst;
		if (body == null || body.kind != TypeKind.Struct) continue;
		for (const held of heldBeyond(body)) {
			if (hasGenericParams(held) || !hasTypeIdentity(held)) return true;
			const key = typeIdentity(held);
			if (nameSetContains(seen, key)) continue;
			nameSetAdd(seen, key);
			if (nameSetContains(cyclicCache, key) || cfaAux(held, key, false, createNameSet())) return true;
			slots.push(held);
		}
	}
	return false;
}

export function isAcyclicRefElement(elem: Type | null, cyclicCache: NameSet, acyclicCache: NameSet): boolean {
	const bare = countedEvictElement(elem);
	return bare != null && bare.kind == TypeKind.Ref && !isAtomicRef(bare) && !canFormAcycle(bare, cyclicCache, acyclicCache);
}

// Whether the lifted trace of a cell of type `t` reaches any cell: the reference lifts a
// trace for every type and it is non-trivial when the type can form a cycle itself, or when
// a field held by value (through structs, tuples, unions and arrays) is a closure or a ref
// whose pointee can form a cycle (liftdestructors.nim fillBodyObj, atomicRefOp attachedTrace).
// A ref to an acyclic pointee ends the walk, as its trace does.
export function traceReachesCycle(t: Type | null, cyclicCache: NameSet, acyclicCache: NameSet): boolean {
	if (canFormAcycle(t, cyclicCache, acyclicCache)) return true;
	if (t == null) return false;
	const subject = t.kind == TypeKind.Ref ? t.typeReturn : t;
	return traceEdgeAux(subject, true, cyclicCache, acyclicCache, createNameSet());
}

export function cellTraceHasEdge(t: Type | null, cyclicCache: NameSet, acyclicCache: NameSet): boolean {
	if (t == null) return false;
	const subject = t.kind == TypeKind.Ref ? t.typeReturn : t;
	return traceEdgeAux(subject, true, cyclicCache, acyclicCache, createNameSet());
}

function traceEdgeAux(t: Type | null, top: boolean, cyclicCache: NameSet, acyclicCache: NameSet, marker: NameSet): boolean {
	if (t == null) return false;
	if (!top && (t.kind == TypeKind.Ref || unwrapRefNullUnion(t) != null)) {
		const ref = t.kind == TypeKind.Ref ? t : unwrapRefNullUnion(t)!;
		if (ref.kind != TypeKind.Ref) return traceEdgeAux(ref, false, cyclicCache, acyclicCache, marker);
		if (isAtomicRef(ref)) return false;
		return canFormAcycle(ref, cyclicCache, acyclicCache);
	}
	return match (t.kind) {
		TypeKind.Function | TypeKind.Unknown => true,
		TypeKind.Struct | TypeKind.Union | TypeKind.Tuple => firstVisit(typeIdentity(t), marker) && traceEdgeFields(t, cyclicCache, acyclicCache, marker),
		TypeKind.GenericInstance => {
			if (isAwaitable(t)) return false;
			if (t.typeReturn == null) {
				const params = genericParamsOf(t);
				if (params != "") instantiateGenericBody(t, params);
			}
			if (!firstVisit(typeIdentity(t), marker)) return false;
			const body = t.typeReturn;
			if (body == null) return false;
			if (body.kind == TypeKind.Struct || body.kind == TypeKind.Union || body.kind == TypeKind.Tuple) return traceEdgeFields(body, cyclicCache, acyclicCache, marker);
			return traceEdgeAux(body, top, cyclicCache, acyclicCache, marker);
		},
		TypeKind.Array | TypeKind.SizedArray => traceEdgeAux(t.typeReturn, false, cyclicCache, acyclicCache, marker),
		TypeKind.Distinct | TypeKind.Alias => traceEdgeAux(t.typeReturn, top, cyclicCache, acyclicCache, marker),
		_ => false,
	};
}

function firstVisit(key: string, marker: NameSet): boolean {
	if (key == "") return true;
	if (nameSetContains(marker, key)) return false;
	nameSetAdd(marker, key);
	return true;
}

function traceEdgeFields(t: Type, cyclicCache: NameSet, acyclicCache: NameSet, marker: NameSet): boolean {
	const base = t.kind == TypeKind.Struct && t.typeExtra != null && t.typeExtra.kind == TypeKind.Ref ? t.typeExtra.typeReturn : t.typeExtra;
	if (t.kind == TypeKind.Struct && traceEdgeAux(base, true, cyclicCache, acyclicCache, marker)) return true;
	for (const child of t.typeChildren) {
		if (traceEdgeAux(child, false, cyclicCache, acyclicCache, marker)) return true;
	}
	return false;
}

// Whether the walk that takes a cell's graph out of its thread's cycle roots reaches a cell
// that can form a cycle. Unlike the trace it goes on through a ref to an acyclic pointee:
// such a cell is never a root, but a cyclic cell behind it can be one.
export function custodyReaches(t: Type | null, cyclicCache: NameSet, acyclicCache: NameSet): boolean {
	if (canFormAcycle(t, cyclicCache, acyclicCache)) return true;
	if (t == null) return false;
	const subject = t.kind == TypeKind.Ref ? t.typeReturn : t;
	return custodyEdgeAux(subject, true, cyclicCache, acyclicCache, createNameSet());
}

function countedRefOf(t: Type): Type | null {
	const ref = t.kind == TypeKind.Ref ? t : unwrapRefNullUnion(t);
	if (ref == null || ref.kind != TypeKind.Ref || isAtomicRef(ref)) return null;
	return ref;
}

function isRefLike(t: Type): boolean {
	return t.kind == TypeKind.Ref || unwrapRefNullUnion(t) != null;
}

function custodyEdgeAux(t: Type | null, top: boolean, cyclicCache: NameSet, acyclicCache: NameSet, marker: NameSet): boolean {
	if (t == null) return false;
	if (!top && isRefLike(t)) {
		const ref = countedRefOf(t);
		if (ref == null || isActorRef(ref)) return false;
		if (canFormAcycle(ref, cyclicCache, acyclicCache)) return true;
		return custodyEdgeAux(ref.typeReturn, true, cyclicCache, acyclicCache, marker);
	}
	return match (t.kind) {
		TypeKind.Function | TypeKind.Unknown => true,
		TypeKind.Struct | TypeKind.Union | TypeKind.Tuple => firstVisit(typeIdentity(t), marker) && custodyEdgeFields(t, cyclicCache, acyclicCache, marker),
		TypeKind.GenericInstance => {
			const body = instanceBody(t);
			if (body == null || !firstVisit(typeIdentity(t), marker)) return false;
			if (body.kind == TypeKind.Struct || body.kind == TypeKind.Union || body.kind == TypeKind.Tuple) return custodyEdgeFields(body, cyclicCache, acyclicCache, marker);
			return custodyEdgeAux(body, top, cyclicCache, acyclicCache, marker);
		},
		TypeKind.Array | TypeKind.SizedArray => custodyEdgeAux(t.typeReturn, false, cyclicCache, acyclicCache, marker),
		TypeKind.Distinct | TypeKind.Alias => custodyEdgeAux(t.typeReturn, top, cyclicCache, acyclicCache, marker),
		_ => false,
	};
}

function custodyEdgeFields(t: Type, cyclicCache: NameSet, acyclicCache: NameSet, marker: NameSet): boolean {
	const base = t.kind == TypeKind.Struct && t.typeExtra != null && t.typeExtra.kind == TypeKind.Ref ? t.typeExtra.typeReturn : t.typeExtra;
	if (t.kind == TypeKind.Struct && custodyEdgeAux(base, true, cyclicCache, acyclicCache, marker)) return true;
	for (const child of t.typeChildren) {
		if (custodyEdgeAux(child, false, cyclicCache, acyclicCache, marker)) return true;
	}
	for (const held of heldBeyond(t)) {
		if (hasGenericParams(held) || !hasTypeIdentity(held) || custodyEdgeAux(held, true, cyclicCache, acyclicCache, marker)) return true;
	}
	return false;
}

function instanceBody(t: Type): Type | null {
	if (isAwaitable(t)) return null;
	if (t.typeReturn == null) {
		const params = genericParamsOf(t);
		if (params != "") instantiateGenericBody(t, params);
	}
	return t.typeReturn;
}

function isActorRef(ref: Type): boolean {
	return ref.sym != null && ref.sym.symbolKind == SymbolKind.Actor;
}

// Whether the lifted custody walk of a value of type `t` differs from its trace: some edge of
// it is walked by custody and skipped by the trace. Mirrors the gates of the lifted bodies —
// a ref field or element pushed when its pointee is cyclic or reaches a cycle, a value field
// walked when it reaches one, an array element looped when it can form a cycle — so a type
// without a difference keeps its trace as its custody walk.
export function custodyAddsEdge(t: Type | null, cyclicCache: NameSet, acyclicCache: NameSet): boolean {
	return addsAux(t, true, cyclicCache, acyclicCache, createNameSet());
}

function addsAux(t: Type | null, top: boolean, cyclicCache: NameSet, acyclicCache: NameSet, marker: NameSet): boolean {
	if (t == null) return false;
	if (!top && isRefLike(t)) {
		const ref = countedRefOf(t);
		if (ref == null || isActorRef(ref) || canFormAcycle(ref, cyclicCache, acyclicCache)) return false;
		return custodyReaches(ref.typeReturn, cyclicCache, acyclicCache);
	}
	return match (t.kind) {
		TypeKind.Struct | TypeKind.Union | TypeKind.Tuple => {
			if (!top && !custodyReaches(t, cyclicCache, acyclicCache)) return false;
			if (!top && !traceReachesCycle(t, cyclicCache, acyclicCache)) return true;
			return firstVisit(typeIdentity(t), marker) && addsFields(t, cyclicCache, acyclicCache, marker);
		},
		TypeKind.GenericInstance => {
			const body = instanceBody(t);
			if (body == null) return false;
			if (!top && !custodyReaches(t, cyclicCache, acyclicCache)) return false;
			if (!top && !traceReachesCycle(t, cyclicCache, acyclicCache)) return true;
			if (!firstVisit(typeIdentity(t), marker)) return false;
			if (body.kind == TypeKind.Struct || body.kind == TypeKind.Union || body.kind == TypeKind.Tuple) return addsFields(body, cyclicCache, acyclicCache, marker);
			return addsAux(body, top, cyclicCache, acyclicCache, marker);
		},
		TypeKind.Array => {
			const elem = t.typeReturn;
			if (!custodyReaches(elem, cyclicCache, acyclicCache)) return false;
			if (!canFormAcycle(elem, cyclicCache, acyclicCache)) return true;
			return addsAux(elem, false, cyclicCache, acyclicCache, marker);
		},
		TypeKind.SizedArray => {
			const elem = t.typeReturn;
			if (!custodyReaches(elem, cyclicCache, acyclicCache)) return false;
			if (!traceReachesCycle(elem, cyclicCache, acyclicCache)) return true;
			return addsAux(elem, false, cyclicCache, acyclicCache, marker);
		},
		TypeKind.Distinct | TypeKind.Alias => addsAux(t.typeReturn, top, cyclicCache, acyclicCache, marker),
		_ => false,
	};
}

function addsFields(t: Type, cyclicCache: NameSet, acyclicCache: NameSet, marker: NameSet): boolean {
	const base = t.kind == TypeKind.Struct && t.typeExtra != null && t.typeExtra.kind == TypeKind.Ref ? t.typeExtra.typeReturn : t.typeExtra;
	if (t.kind == TypeKind.Struct && addsAux(base, true, cyclicCache, acyclicCache, marker)) return true;
	for (const child of t.typeChildren) {
		if (addsAux(child, false, cyclicCache, acyclicCache, marker)) return true;
	}
	return false;
}
