// @stdout: string values false false false true false true
// @stdout: string length 3 5
// @stdout: nullable other dots other
// @stdout: number values false true true

type Lt = "n" | "w";
type Lt0 = "red" | "green";
type Style = "solid" | "wavy" | "dotted";
type Num = 1 | 2 | 3;

function eq(d: Lt, e: Lt): boolean { return d == e; }
function strict(d: Lt, e: Lt): boolean { return d === e; }
function ne(d: Lt, e: Lt): boolean { return d != e; }
function sne(d: Lt, e: Lt): boolean { return d !== e; }
function constant(d: Lt): boolean { return d == "w"; }
function lenA(d: Lt0): int32 { return d.length; }
function f(own: Style | null): string { if (own === "dotted") return "dots"; return "other"; }
function numEq(a: Num, b: Num): boolean { return a === b; }

console.log(`string values ${eq("w", "n")} ${strict("w", "n")} ${constant("n")} ${ne("w", "n")} ${sne("w", "w")} ${eq("n", "n")}`);
console.log(`string length ${lenA("red")} ${lenA("green")}`);
console.log(`nullable ${f("solid")} ${f("dotted")} ${f(null)}`);
console.log(`number values ${numEq(1, 2)} ${numEq(3, 3)} ${numEq(2, 2)}`);
