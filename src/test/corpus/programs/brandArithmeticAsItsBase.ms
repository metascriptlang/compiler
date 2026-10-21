// @stdout: int 6 4 10 10 1 2 1 10
// @stdout: number 2 2.25 6.5 -0.5
// @stdout: declared T505
// @stdout: text abab ab5 x6 T5!
// note: arithmetic and bitwise operators on a TS brand (`int32 & { __brand: "Id" }`) apply to its base, so
// `x / 2` divides as int32, `r + 0.5` adds as number and a string brand concatenates; an operator or a
// toString declared for the brand still wins.
// A user `distinct` is refused instead (handoff/distinctArithmetic.ms).
type Id = int32 & { __brand: "Id" };
type R = number & { __brand: "R" };
type Tag = int32 & { __brand: "Tag" };
type Name = string & { __brand: "Name" };

function `+`(a: Tag, b: Tag): Tag { return ((a as int32) * 100 + (b as int32)) as Tag; }
function toString(this t: Tag): string { return "T" + (t as int32).toString(); }

const x = 5 as Id;
const r = 1.5 as R;
const t = 5 as Tag;
const n = "ab" as Name;
console.log(`int ${x + 1} ${x - 1} ${x + x} ${x * 2} ${x % 2} ${x / 2} ${x & 1} ${x << 1}`);
console.log(`number ${r + 0.5} ${r * r} ${x + r} ${1 - r}`);
console.log(`declared ${t + t}`);
console.log("text " + (n + n) + " " + (n + x) + " " + ("x" + (x + 1)) + " " + (t + "!"));
