// @stdout: 5 u1 7 | 5 | 11 16 | 1 5
// note: a TS brand (`int32 & { __brand: "Id" }`) as the type argument of a generic struct. The
// instance's C name used to carry the brand text `__brand:"Id"` and failed clang; two brands
// need two C names, and the same brand declared again in another module is the same type.
import { Box, boxedId } from "./ids";

type Id = int32 & { __brand: "Id" };
type Age = int32 & { __brand: "Age" };
type UserId = string & { __brand: "UserId" };

const id: Box<Id> = { v: 5 as Id };
const user: Box<UserId> = { v: "u1" as UserId };
const age: Box<Age> = { v: 7 as Age };
const nested: Box<Box<Id>> = { v: id };
const fromLib: Box<Id> = boxedId(11);
const xs: Box<Id>[] = [id];

const idValue: int32 = id.v;
const userValue: string = user.v;
const ageValue: int32 = age.v;
const nestedValue: int32 = nested.v.v;
const libValue: int32 = fromLib.v;
const sum: int32 = fromLib.v + id.v;
const firstValue: int32 = xs[0].v;
console.log(`${idValue} ${userValue} ${ageValue} | ${nestedValue} | ${libValue} ${sum} | ${xs.length} ${firstValue}`);
