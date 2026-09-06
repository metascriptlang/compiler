// bug037 — Ref<Union> heap allocation skipped destroyFn → RC field leak
//
// Symptom:    Ref-wrapped match-type Union (e.g. JsonValue = Ref<JsonValueData>)
//             used `msAlloc` instead of `msAllocTyped(&XTypeInfo)`. msRefHeader.type
//             stayed NULL → msDecrefCyclic skipped destroyFn → RC payload fields
//             (strings, arrays, nested Ref<Union>) leaked. 1M parseJson: ~580 MB.
//
// Root cause: (1) destructorLifting `shouldEmitTypeInfo` predicate only matched
//                 `isClassOrInterface` — Union TypeAliases skipped.
//             (2) Codegen Ref<Union> object-literal site emitted bare msAlloc;
//                 class `new` already used msAllocTyped via ensureTypeInfoDef.
//
// Fix:        - destructorLifting: `isHeapAllocated = isClassOrInterface || Union`
//             - codegen: ensureTypeInfoDef + msAllocTyped (mirrors class `new`).
//
// Reference: Nim liftdestructors.nim:701 atomicRefOp forwards createTypeBoundOps
//            into elementType — Nim has no tyUnion (variants are tyObject), so
//            ref-to-variant gets TypeInfo uniformly.

enum Bug037Kind { Ok, Err }

type Bug037Body<T, E> = match (kind: Bug037Kind) {
	Bug037Kind.Ok => { value: T },
	Bug037Kind.Err => { error: E },
};

type Bug037Ref<T, E> = Ref<Bug037Body<T, E>>;

function bug037MakeOk(s: string): Bug037Ref<string, number> {
	return { kind: Bug037Kind.Ok, value: s };
}

function bug037MakeErr(n: number): Bug037Ref<string, number> {
	return { kind: Bug037Kind.Err, error: n };
}

test "bug037: Ref<Union> with string payload — field access + destroy path" {
	const ok = bug037MakeOk("hello-payload");
	if (ok.kind == Bug037Kind.Ok) assert ok.value == "hello-payload";

	const err = bug037MakeErr(42);
	if (err.kind == Bug037Kind.Err) assert err.error == 42;
}
