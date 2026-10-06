// @stdout: true n7 s n3 two arr1
// note: a union is one type whatever order its members are written in, across modules too: a value moves between `int32 | string` and `string | int32` (nullable, inside an array, through a generic return, through `as`) with no conversion. Same output on C, JS and the Raiser.
import { A, makeA } from "./unionOrderA";
import { B, makeB } from "./unionOrderB";
function show(v: string | int32): string { return typeof v == "string" ? v : `n${v}`; }
function pick<T>(v: T | string, alt: T): T | string { return v; }
const a: A = makeA();
const b: B = makeB();
a.v = b.v;
const first = `${a.v != null}`;
const x: int32 | string = 7;
const y: string | int32 = x;
const second = show(y);
let z: boolean | string | int32 = true;
z = "s";
const w: int32 | boolean | string = z;
const third = `${typeof w == "string" ? w : "?"}`;
const p: string | int32 = pick<int32>(3, 4);
const fourth = show(p);
const arr: (string | int32)[] = [1, "two"];
const arr2: (int32 | string)[] = arr;
const v6: int32 | string | int32[] = [1] as int32 | int32[] | string;
const sixth = typeof v6 == "object" ? `arr${v6.length}` : "?";
console.log(`${first} ${second} ${third} ${fourth} ${show(arr2[1])} ${sixth}`);
