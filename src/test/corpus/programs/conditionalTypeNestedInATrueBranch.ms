// @stdout: nested is-a other-string not-string is-a other-string not-string 1 2 3 4 1 2 3 4
// note: a conditional type nested in the true branch of another needs no parentheses, as in TypeScript: `T extends string ? T extends "a" ? X : Y : Z` keeps the inner conditional whole in the true branch, and so does a nesting two levels deep and a nesting in both branches. Each binding is typed by the leaf it names, so a wrong leaf is a compile error. Before, the outer conditional ended at the inner one's `:`, an internal error on C and `<object>` on JS. Same output on C, JS and the Raiser.
type Bare<T> = T extends string ? T extends "a" ? "is-a" : "other-string" : "not-string";
type Paren<T> = T extends string ? (T extends "a" ? "is-a" : "other-string") : "not-string";
type TwoDeep<T, U> = T extends string ? U extends string ? T extends "a" ? 1 : 2 : 3 : 4;
type BothSides<T> = T extends string ? T extends "a" ? 1 : 2 : T extends int32 ? 3 : 4;

const b1: Bare<"a"> = "is-a";
const b2: Bare<"z"> = "other-string";
const b3: Bare<int32> = "not-string";
const p1: Paren<"a"> = "is-a";
const p2: Paren<"z"> = "other-string";
const p3: Paren<int32> = "not-string";
const d1: TwoDeep<"a", "x"> = 1;
const d2: TwoDeep<"b", "x"> = 2;
const d3: TwoDeep<"a", int32> = 3;
const d4: TwoDeep<int32, "x"> = 4;
const s1: BothSides<"a"> = 1;
const s2: BothSides<"z"> = 2;
const s3: BothSides<int32> = 3;
const s4: BothSides<boolean> = 4;
console.log(`nested ${b1} ${b2} ${b3} ${p1} ${p2} ${p3} ${d1} ${d2} ${d3} ${d4} ${s1} ${s2} ${s3} ${s4}`);
