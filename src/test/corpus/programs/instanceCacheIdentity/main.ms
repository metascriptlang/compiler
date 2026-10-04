// @stdout: 7 9 ok
// @stdout: B A 7
// @stdout: 11 5 6
// @stdout: true 1

import { Box, repeat, shifted } from "./library";

enum Left { A, B }
enum Right { A, B }

function first<T>(values: T[]): T { return values[0]; }

const a = new Box<int32>(repeat<int32>(7, 3));
const b = new Box<int32>(repeat<int32>(9, 2));
const c = new Box<string>(repeat<string>("ok", 2));
const left = new Box<Left>(repeat<Left>(Left.B, 2));
const right = new Box<Right>(repeat<Right>(Right.A, 2));
const nested = new Box<Box<int32>>(a);
const values: int32[] = [11, 13];
console.log(a.value, b.value, c.value);
console.log(left.value.toString(), right.value.toString(), nested.value.value);
console.log(first<int32>(values), shifted<int32>(7, 3), shifted<string>("x", 4));
const set = new HashSet<int32>();
set.add(5);
set.add(5);
console.log(set.has(5), set.size);
