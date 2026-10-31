// Destructuring names `length` of a string or an array as a member to read, not as a missing property
//
// INVARIANT: `const { length } = "abc"` and the same over an array are refused because destructuring lowers
//   stored fields only, and the refusal says to read `length` as a member; the type does have that member.
//
// WHAT IT CATCHES: the missing-property lookup of the destructuring check skipping the built-in `length`
//   that member access resolves, so the message claimed `Property 'length' does not exist on type 'string'`.
//
// RED MEANS: the refusal says the property does not exist, or one of the shapes compiled.
//
// GUARD-CHECK-FAIL cannot destructure 'length' from 'string': read it as a member
// GUARD-CHECK-FAIL cannot destructure 'length' from 'int32[]': read it as a member
// GUARD-JS

const text = "abc";
const list: int32[] = [1, 2];
const { length } = text; // GUARD-REFUSED
const { length: count } = list; // GUARD-REFUSED
console.log(length, count, text.length, list.length);
