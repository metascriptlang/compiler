// @stdout: A B 100 65 66 67 char int int false true
// note: char takes only char: an int literal or run-time int becomes a char with `as char`, a char reaches an integer slot with `as int8`/`as int16`/`as int32`, a `char | null` slot takes `as char`, and a char argument picks the char overload. The checker refuses the implicit forms (checker3pass/scenarios/charAcceptsOnlyChar.ms); these explicit ones print the same on C, JS and the Raiser.
function k(n: int32): int32 { return n; }
function over(x: int32): string { return "int"; }
function over(x: char): string { return "char"; }
const a: char = 65 as char;
const b: char = k(66) as char;
const i8: int8 = (k(100) as char) as int8;
const i16: int16 = a as int16;
const i32: int32 = b as int32;
const u: char | null = 67 as char;
console.log(a, b, i8, i16, i32, u !== null ? u as int32 : -1, over(a), over(i32), over(b as int32), a == b, a < b);
