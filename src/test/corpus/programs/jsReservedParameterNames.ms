// @stdout: arrow 2
// @stdout: arrows 20
// @stdout: function 5
// @stdout: nested 7
// @exit: 0
// note: a parameter named by a word JavaScript reserves is declared under the same JS name its reads use, in an arrow with one or several parameters and in a function expression.

const one = (short: int32): int32 => short + 1;
const two = (short: int32, int: int32): int32 => short * int;
const fn = function (short: int32, volatile: int32): int32 { return short + volatile; };
type Thunk = () => int32;
const outer = (final: int32): Thunk => () => final + 2;

console.log("arrow", one(1));
console.log("arrows", two(4, 5));
console.log("function", fn(2, 3));
console.log("nested", outer(5)());
