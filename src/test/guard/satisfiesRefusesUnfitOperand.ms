// `e satisfies T` refuses an operand that does not fit T and keeps the operand's own type
//
// INVARIANT: the operand is related to Readonly<T>; a misfit is `does not satisfy`, a fresh object literal
//   meets T's excess-property check, and the result is the operand's type, never T.
//
// WHAT IT CATCHES: satisfies erased without its check, or acting as a cast that retypes its operand.
//
// RED MEANS: one of the refused lines compiled.
//
// GUARD-CHECK-FAIL does not satisfy the expected type 'Shape'
// GUARD-CHECK-FAIL a read-only view never converts back to the mutable type
// GUARD-JS

interface Shape { kind: string; size: number }
const count: int32 = 4;
const a = count satisfies Shape; // GUARD-REFUSED
const b = { kind: "x", size: 1, extra: true } satisfies Shape; // GUARD-REFUSED
const c = "circle" satisfies "square" | "triangle"; // GUARD-REFUSED
const view: Readonly<Shape> = { kind: "ro", size: 1 };
const widened: Shape = view satisfies Shape; // GUARD-REFUSED
console.log(a, b, c, widened);
