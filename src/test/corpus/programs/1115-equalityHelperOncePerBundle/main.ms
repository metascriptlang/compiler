// @stdout: struct=true,false,true,false bytes=true,false box=true,false pair=false,true,true,false
// note: two modules compare structs that share a nested struct and a `uint8[32]` field, a generic struct instance, a sized array and a tuple. Each generated equality helper exists once per program, so the bundle still loads when it is an ES module (the top-level await makes it one). Same output on every backend.

import { First, Second, Box } from "./lib/types";
import { sameFirst, sameBytesFirst, sameBoxFirst, pairFirst } from "./lib/viaFirst";
import { sameSecond, sameBytesSecond, sameBoxSecond, pairSecond } from "./lib/viaSecond";

async function seed(n: int32): Promise<int32> { return n; }

const seven = await seed(7);
let bytes: uint8[32] = [];
bytes[0] = seven as uint8;
let other: uint8[32] = [];
other[31] = 1;
const f: First = { leaf: { bits: 7 }, bytes: bytes };
const g: First = { leaf: { bits: 8 }, bytes: bytes };
const s: Second = { leaf: { bits: 7 }, bytes: bytes };
const t: Second = { leaf: { bits: 7 }, bytes: other };
const box: Box<int32> = { v: seven };
const box2: Box<int32> = { v: 8 };
console.log(`struct=${sameFirst(f, f)},${sameFirst(f, g)},${sameSecond(s, s)},${sameSecond(s, t)} bytes=${sameBytesFirst(bytes, bytes)},${sameBytesSecond(bytes, other)} box=${sameBoxFirst(box, box)},${sameBoxSecond(box, box2)} pair=${pairFirst([1, 2], [1, 3])},${pairSecond([4, 4], [4, 4])}`);
