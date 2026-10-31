// an object literal under `as const` is readonly, nested ones included
//
// INVARIANT: every object literal in a const context has readonly properties, whatever its values are.
//
// WHAT IT CATCHES: the const context stopping at the outer literal, or at a non-literal value.
//
// RED MEANS: a write to a property of a const object compiled.
//
// GUARD-CHECK-FAIL cannot write through Readonly<{ kind: "x"; n: number;
// GUARD-CHECK-FAIL cannot write through Readonly<{ k: "z"; }>
// GUARD-JS

function f(): number { return 1; }
const o = { kind: "x", n: f(), inner: { k: "z" } } as const;
o.n = 2; // GUARD-REFUSED
o.inner.k = "y"; // GUARD-REFUSED
console.log(o);
