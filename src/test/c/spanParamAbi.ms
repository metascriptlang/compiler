// A Span parameter is passed to C as its element pointer and a length, never as a pointer to the span
// struct; the body rebuilds the span value from the two. Runtime behaviour: corpus `spanParamAbi`.

import { compileToC } from "../helpers";

function lineOf(c: string, fn: string): string {
	for (const line of c.split("\n")) {
		if (line.contains(` ${fn}__`) && line.endsWith("{")) return line;
	}
	return "";
}

const SRC = `
struct Pt { x: int32; y: int32; }
function sumLocal(xs: Span<int64>): int64 { let s: int64 = 0; for (let i = 0; i < xs.length; i += 1) s += xs[i]; return s; }
export function sumPub(xs: Span<int64>): int64 { let s: int64 = 0; for (let i = 0; i < xs.length; i += 1) s += xs[i]; return s; }
function sumPts(ps: Span<Pt>, k: int32): int32 { let s: int32 = k; for (let i = 0; i < ps.length; i += 1) s += ps[i].x; return s; }
export function sumPtsPub(ps: Span<Pt>): int32 { return sumPts(ps, 0); }
const v: int64[] = [1, 2, 3];
const pts: Pt[] = [{ x: 1, y: 2 }];
console.log(sumLocal(v) + sumPub(v) + sumPts(pts, 1) + sumPtsPub(pts));
`;

test "a module-local Span parameter is a data pointer and a length" {
	const c = compileToC(SRC);
	assert c.ok;
	assert lineOf(c.value, "sumLocal").contains("(int64_t* xsData_0, int64_t xsLen_0)");
}

test "an exported Span parameter is a data pointer and a length" {
	const c = compileToC(SRC);
	assert c.ok;
	assert lineOf(c.value, "sumPub").contains("(int64_t* xsData_0, int64_t xsLen_0)");
}

test "a struct-element Span parameter is a data pointer and a length" {
	const c = compileToC(SRC);
	assert c.ok;
	assert lineOf(c.value, "sumPts").contains("* psData_0, int64_t psLen_0, int32_t k)");
	assert lineOf(c.value, "sumPtsPub").contains("* psData_0, int64_t psLen_0)");
}

test "no function takes a pointer to a span struct" {
	const c = compileToC(SRC);
	assert c.ok;
	assert !c.value.contains("msSpan_int64_t* ");
}

test "a call passes the span's data and length" {
	const c = compileToC(SRC);
	assert c.ok;
	let call = "";
	for (const line of c.value.split("\n")) {
		if (line.contains("= sumLocal__")) call = line;
	}
	assert call.contains(".data, ");
	assert call.endsWith(".len);");
	assert !call.contains("&(");
}
