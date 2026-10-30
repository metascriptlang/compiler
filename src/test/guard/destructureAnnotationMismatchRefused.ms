// A destructuring annotation is the declared type of the pattern, so the initializer is checked against it
//
// INVARIANT: `const { x: v }: T = init` is refused when `init` is not assignable to `T`, and a field the
//   pattern names that `T` lacks is refused as a read of it would be.
//
// WHAT IT CATCHES: the parser dropping the annotation, which let a mismatched initializer bind silently.
//
// RED MEANS: one of the shapes compiled. The same annotation over a matching initializer still binds.
//
// GUARD-CHECK-FAIL Property 'y' does not exist on type
// GUARD-JS

interface GuardAnnSrc { x: string; }
const src: GuardAnnSrc = { x: "a" };
const lit = { x: 1 };
const { x: ok }: { x: string } = src;
const { x: bad }: { x: string } = lit; // GUARD-REFUSED
const { y }: { x: string } = src; // GUARD-REFUSED
console.log(ok, bad, y);
