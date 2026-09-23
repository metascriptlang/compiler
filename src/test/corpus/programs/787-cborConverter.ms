// @xfail(raiser): error: Cannot resolve module 'std/core/buffer'
// Parity program — a CBOR value reads through the CBOR converters once they
// are imported: a typed slot, an argument, `as U`, and an operand whose
// other side is typed.
//
// @stdout: slot Ann 41|arg 41|as 41|op 42 hi Ann true
// @exit: 0

import { CborValue, cborToString, cborToInt32 } from "std/serialize/cbor";
import { cborInt, cborText, cborTextMap } from "std/serialize/cbor/builder";
import { getDynamicField } from "std/serialize/cbor/accessors";

function take(n: int32): int32 { return n; }

const c: CborValue = cborTextMap(["name", "age"], [cborText("Ann"), cborInt(41 as int64)]);
const name: string = c.name;
const age: int32 = c.age;
const arg = take(c.age);
const cast = c.age as int32;
const next = c.age + 1;
const greet = "hi " + c.name;
const older = c.age > 40;
console.log(`slot ${name} ${age}|arg ${arg}|as ${cast}|op ${next} ${greet} ${older}`);
