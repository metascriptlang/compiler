// @stdout: leaf node leaf node leaf node node
// note: the check type and the extends type of a conditional type are unions, as in TypeScript: `V extends string | number ? A : B` with two and three members and parenthesised, and `V | null extends string`, which does not distribute because its check type is no naked type parameter. Each binding below is typed by the branch it names, so a wrong branch is a compile error. Before, an unparenthesised union after `extends` was "Parse: ';' expected before '|'" and a parenthesised one was not read as a conditional. Same output on C, JS and the Raiser.
type Leaf<V> = V extends string | number ? "leaf" : "node";
type Three<V> = V extends string | number | boolean ? "leaf" : "node";
type Paren<V> = V extends (string | number) ? "leaf" : "node";
type Checked<V> = V | null extends string ? "leaf" : "node";

const a: Leaf<string> = "leaf";
const b: Leaf<string[]> = "node";
const c: Three<boolean> = "leaf";
const d: Three<int32[]> = "node";
const e: Paren<int32> = "leaf";
const f: Paren<boolean> = "node";
const g: Checked<string> = "node";
console.log(`${a} ${b} ${c} ${d} ${e} ${f} ${g}`);
