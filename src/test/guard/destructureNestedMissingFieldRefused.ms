// A nested destructured field the inner type lacks is refused at its own level
//
// INVARIANT: every level of an object pattern names only fields that level's type has; a missing inner
//   one is `Property 'f' does not exist on type 'T'` with T the inner type, as the read `src.a.f` is.
//
// WHAT IT CATCHES: the nested alias binding nothing or an untyped slot, which C reports as an undefined
//   variable and JS runs as `undefined`.
//
// RED MEANS: a nested pattern named a field the inner type lacks and compiled.
//
// GUARD-CHECK-FAIL Property 'gone' does not exist on type 'GuardInner'
// GUARD-CHECK-FAIL Property 'absent' does not exist on type 'GuardInner'
// GUARD-JS

interface GuardInner { n: int32; }
interface GuardOuter { a: GuardInner; }
const src: GuardOuter = { a: { n: 1 } };
const { a: { n } } = src;
const { a: { gone } } = src; // GUARD-REFUSED
const { a: { n: kept, absent: other } } = src; // GUARD-REFUSED
console.log(n, gone, kept, other);
