import { fq } from "./q";
console.log("p");
export function fp(n: int32): int32 { return n > 0 ? fq(n - 1) + 1 : 0; }
