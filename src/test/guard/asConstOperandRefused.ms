// `as const` is refused on an operand that has no literal type to keep
//
// INVARIANT: `x as const` applies to a string, number, boolean or object literal, or an enum member;
//   any other operand is `a 'const' assertion can only be applied to ...`, and an array literal or an
//   object literal holding a non-literal value names the part this language cannot type yet.
//
// WHAT IT CATCHES: the assertion being erased for a call result, which would widen it silently.
//
// RED MEANS: one of the operands compiled, or a literal operand stopped compiling.
//
// GUARD-CHECK-FAIL a 'const' assertion can only be applied to references to enum members, or string, number, boolean or object literals
// GUARD-CHECK-FAIL 'as const' on an array literal is not supported: it would need a readonly tuple type
// GUARD-CHECK-FAIL 'as const' on an object literal needs every property value to be a string, number, boolean or object literal
// GUARD-JS

function f(): number { return 1; }
const nested = { a: "x", b: [1] } as const; // GUARD-REFUSED
const call = f() as const; // GUARD-REFUSED
const array = [1, 2] as const; // GUARD-REFUSED
const mixed = { a: f() } as const; // GUARD-REFUSED
const fine = { a: "x", n: 1 } as const;
console.log(nested, call, array, mixed, fine);
