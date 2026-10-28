// @stdout: 2 1 1 2 2 2 3
import { ONE, TWO } from "./consts";
const LOCAL: int32 = 1;
const CHAIN: int32 = LOCAL;
const UNTYPED = 1;
const SUM: int32 = LOCAL + 1;
struct S {
	a: int32[SUM];
	b: int32[CHAIN];
	c: int32[UNTYPED];
	d: int32[LOCAL + 1];
	e: int32[TWO];
	f: int32[ONE + 2];
}
const s: S = {};
console.log(`${s.a.length} ${s.b.length} ${s.c.length} ${s.d.length} ${s.e.length} ${s.e.length} ${s.f.length}`);
