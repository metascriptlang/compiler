// @xfail(raiser): error: Cannot resolve module 'std/core/buffer'
// @stdout: generic-instance-cbor all-ok
// note: the CBOR codec reads a generic instance through its implementation, at the top level, as a field and as an array element.
import { cborEncode, decode, cborValueToStruct, cborInt, _cborArrayOfStructs, _cborToStructArray } from "std/serialize/cbor";

type G<T> = { v: T; w: int32 };
interface Box<T> { v: T; w: int32 }
interface BHolder { b: Box<int32>; s: Box<string> }
interface BArr { bs: Box<int32>[] }

let failures = 0;
function check(name: string, ok: boolean): void {
	if (!ok) {
		console.log("FAIL " + name);
		failures = failures + 1;
	}
}

const g: G<int32> = { v: 5, w: 6 };
const rg = decode(cborEncode(g));
const qg: G<int32> = cborValueToStruct(rg.ok ? rg.value : cborInt(0), null as G<int32> | null);
check("alias int", rg.ok && qg.v == 5 && qg.w == 6);

const s: G<string> = { v: "x", w: 6 };
const rs = decode(cborEncode(s));
const qs: G<string> = cborValueToStruct(rs.ok ? rs.value : cborInt(0), null as G<string> | null);
check("alias string", rs.ok && qs.v == "x" && qs.w == 6);

const b: Box<int32> = { v: 5, w: 6 };
const rb = decode(cborEncode(b));
const qb: Box<int32> = cborValueToStruct(rb.ok ? rb.value : cborInt(0), null as Box<int32> | null);
check("interface", rb.ok && qb.v == 5 && qb.w == 6);

const h: BHolder = { b: { v: 5, w: 6 }, s: { v: "q", w: 7 } };
const rh = decode(cborEncode(h));
const qh: BHolder = cborValueToStruct(rh.ok ? rh.value : cborInt(0), null as BHolder | null);
check("interface fields", rh.ok && qh.b.v == 5 && qh.s.v == "q" && qh.s.w == 7);

const a: BArr = { bs: [{ v: 1, w: 2 }, { v: 3, w: 4 }] };
const ra = decode(cborEncode(a));
const qa: BArr = cborValueToStruct(ra.ok ? ra.value : cborInt(0), null as BArr | null);
check("array of instances", ra.ok && qa.bs.length == 2 && qa.bs[1].v == 3);

if (failures == 0) {
	console.log("generic-instance-cbor all-ok");
}
