// @stdout: 1 4 pair text b
// note: a type operator whose operand opens with a bracket keeps it: `T extends (infer E)[]` infers like `T extends Array<infer E>`, one array level deeper too, a tuple and a parenthesised type after `extends` are tested, and `keyof (Pair)` names Pair's keys. Before, the annotation text glued the keyword to the bracket (`extends(`, `keyof(`), so the conditional was never read and `keyof(Pair)` was an unresolved type. Same output on C, JS and the Raiser.
interface Row { i: int32; }
interface Pair { a: int32; b: string; }
type Element<T> = T extends (infer E)[] ? E : never;
type Inner<T> = T extends ((infer E)[])[] ? E : never;
type IsPair<T> = T extends [int32, string] ? "pair" : "other";
type IsText<V> = V extends (string) ? "text" : "other";
type PairKey = keyof (Pair);

function first<T>(t: T, e: Element<T>): Element<T> { return e; }

const rows: Row[] = [{ i: 1 }];
const r: Row = first(rows, rows[0]);
const grid: int32[][] = [[4]];
const cell: Inner<int32[][]> = grid[0][0];
const p: IsPair<[int32, string]> = "pair";
const t: IsText<string> = "text";
const k: PairKey = "b";
console.log(`${r.i} ${cell} ${p} ${t} ${k}`);
