// A destructured field the source type lacks is refused, whatever the binding spelling
//
// INVARIANT: an object pattern over a concrete source type names only fields that type has; a
//   missing one is `Property 'f' does not exist on type 'T'`, as the same read `src.f` is.
//
// WHAT IT CATCHES: the pattern binding an untyped slot for a missing field, which C reports as an
//   internal unresolved type and JS runs as `<object>`.
//
// RED MEANS: one of the shapes compiled. A field the source has, with or without a default, still binds.
//
// GUARD-CHECK-FAIL Property 'missing' does not exist on type 'GuardSrc'
// GUARD-CHECK-FAIL Property 'gone' does not exist on type 'GuardSrc'
// GUARD-JS

interface GuardSrc { x: string; y: int32; }
const src: GuardSrc = { x: "a", y: 1 };
const { y = 5, x: s = "z" } = src;
const { missing } = src; // GUARD-REFUSED
const { missing: renamed } = src; // GUARD-REFUSED
const { gone = 1 } = src; // GUARD-REFUSED
console.log(y, s, missing, renamed, gone);
