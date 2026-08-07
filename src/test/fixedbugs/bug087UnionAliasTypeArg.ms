// bug087 — a union ALIAS as a generic type argument failed to instantiate
//
// Symptom:    JSON.parse<Event>(...) / JSON.stringify(e) on a union alias
//             errored "in instantiation of 'JSON_parse<object | object>':
//             Unresolved type 'Event' - missing import?". Interfaces worked.
// Root cause: monoConcreteTypeName renders a NAMED union type arg as its
//             alias name ("Event") when substituting the body's annotation
//             strings, but injectConcreteTypeSyms (src/checker/instantiate.ms)
//             had no Union branch — the name was never injected into the
//             defining module's re-check scope, so resolveAnnotation("Event")
//             hit the resolvePass hard error.
// Fix:        Union branch in injectConcreteTypeSyms: inject t.typeName when
//             named, recurse typeExtra (the match-type's discriminator enum —
//             dropping it regresses to "Undefined variable 'EvKind'") and
//             typeChildren (mirrors the GenericInstance branch).
//
//             Second half of the fix: `_jsonParseTyped` took a `witness: T|null`
//             param that JSON.parse fed a literal `null`, so a by-value union
//             argument emitted `&(MS_NIL)` — "cannot take the address of an
//             rvalue of type 'void *'". The witness only ever carried a type,
//             never a value, so it became `null as T | null` inside the body
//             and left the call boundary entirely.
//
// Still unsupported: a TS-style union whose disc field is enum-typed
// (`{ kind: EvKind.Click }`) decodes wrong — the bridge stamps enum variant
// keys only on match-type DUs, so the codec's TS fallback reads the enum's
// NAME for every variant and emits duplicate match patterns (discDetect.ms
// step 3).

enum EvKind { Click, KeyPress }

type Event = match (kind: EvKind) {
	EvKind.Click => { x: int32 },
	EvKind.KeyPress => { code: string },
};

test "JSON.parse accepts an enum-disc match-type union alias as a type arg" {
	const r = JSON.parse<Event>(`{"kind":"KeyPress","code":"KC_A"}`);
	assert r.ok;
}

test "JSON.stringify accepts a union alias value" {
	const e: Event = { kind: EvKind.KeyPress, code: "KC_A" };
	assert JSON.stringify(e).includes("KC_A");
}

test "JSON.parse union alias still rejects an unknown discriminator" {
	const r = JSON.parse<Event>(`{"kind":"Drag","x":1}`);
	assert !r.ok;
}

