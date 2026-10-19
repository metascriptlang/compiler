// @stdout: 2 1 -1 2.5 3000000000 | 1|-1|2.5
// @exit: 0
// note: console.log of a number-literal set read from a call, a field or a parameter prints its number on every lane — the set is its base for text, not a union the std dump walks (which printed nothing on C and JS).

type Box = { v: 1 | 2 };

function sign(positive: boolean): -1 | 1 { return positive ? 1 : -1; }
function half(whole: boolean): 1 | 2.5 { return whole ? 1 : 2.5; }
function far(k: int32): 3000000000 | 4000000000 { return k > 0 ? 3000000000 : 4000000000; }
function show(v: 1 | 2): string { return `${v}`; }

const box: Box = { v: 2 };
console.log(box.v, sign(true), sign(false), half(false), far(1), "|", `${show(1)}|${sign(false)}|${half(false)}`);
