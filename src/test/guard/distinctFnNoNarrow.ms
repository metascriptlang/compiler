// nim-guard: a `distinct` over a function type widens ONE way
//
// INVARIANT (resolvePass distinct branch sets BrandWiden for a function base; compat.ms
//   brand-widen clause): `type Thunk<T> = distinct (() => T)` flows implicitly into
//   `() => T` — MetaScript's documented divergence (NIM-REF) standing in for the
//   reference's explicit conversion to the base — while a bare closure never flows into
//   the distinct without `as`, which is the reference's own rule for tyDistinct.
//
// WHAT IT CATCHES: the widening bit turning symmetric, or the nominal gate at var-decl
//   letting a closure literal land in a distinct slot.
//
// RED MEANS: `const t2: Thunk<number> = () => 1;` compiles.
//
// GUARD-CHECK-FAIL is not assignable to type 'Thunk<number>'

type Thunk<T> = distinct (() => T);
const t2: Thunk<number> = () => 1;
console.log(t2());
