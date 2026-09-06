// bug116 - monoConcreteTypeName stripped the Ref wrapper from ATOMIC refs,
//           corrupting generic instantiation over Arc<T>
//
// Symptom:    Any js-lane generic whose type argument was an Arc<P> failed the
//             instantiated body re-check with an unhelpful twin message:
//                 in instantiation of 'spawn<Payload>': Return type mismatch
//                 in 'spawn__ref_Payload_...': expected Promise, got Promise
//             (corpus 406-arcSharedBox, surfaced by the 2026-09-01 js audit).
// Root cause: The generic-body re-check substitutes STRING annotations via
//             monoSubstAnnotation(ann, "T", monoConcreteTypeName(T)).
//             monoConcreteTypeName's Ref arm returned the pointee name (the
//             class-annotation convention, where "SomeClass" re-resolves to
//             Ref<Struct> by itself). Applied to Arc<Payload> that spelled T as
//             bare "Payload", so `Promise<T>` re-resolved to Promise<Payload>
//             — no Ref at all — and the return check compared
//             Promise<Arc<Payload>> against Promise<Payload>.
// Fix:        The Ref arm keeps atomic refs wrapped: "Arc<X>" is the spelling
//             resolveAnnotation understands (resolvePass createArc). Plain
//             Refs keep the strip — the class convention is untouched
//             (src/monomorphize/clone.ms monoConcreteTypeName).

import { monoConcreteTypeName } from "../../monomorphize/clone";
import { createArc, createRef, createStruct, int32Type } from "../../checker/types";

test "bug116: monoConcreteTypeName keeps the Arc wrapper" {
	const payload = createStruct("Payload", ["n"], [int32Type()], true);
	assert monoConcreteTypeName(createArc(payload)) == "Arc<Payload>";
}

test "bug116: plain Ref keeps the class-annotation strip" {
	const cls = createStruct("SomeClass", [], [], true);
	assert monoConcreteTypeName(createRef(cls)) == "SomeClass";
}
