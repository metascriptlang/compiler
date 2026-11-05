// E2E C: a loop that pushes once per step onto a fresh array presizes it and writes by index
// (NIM-REF TR-41); runtime results across grow, shrink and raise: corpus presizedPushBuild.

import { compileToC, builtModuleC } from "../helpers";
import { hostTargetInfo } from "../../checker/types";

function emitted(body: string, danger: boolean): string {
	const c = compileToC(`
function f(a: int32[]): int32[] {
	${body}
}
const xs: int32[] = [1, 2, 3];
console.log(f(xs).length);`, hostTargetInfo(), false, true, danger);
	return c.ok ? c.value : "error: " + c.error;
}

function builtC(name: string, body: string, danger: boolean): string {
	const source = `function f(a: int32[]): int32[] {\n\t${body}\n}\nconst xs: int32[] = [1, 2, 3];\nconsole.log(f(xs).length);\n`;
	return builtModuleC("presizedPushEmit", name, source, danger ? ["--danger"] : []);
}

const SET_LEN = "msGenericArraySetLen(";

test "presized push: a mapped toArray sizes its result and cuts it on shrink" {
	const c = builtC("maptoarray", "return a.values().map((x) => x * 2).toArray();", true);
	assert !c.startsWith("error:"), c.slice(0, 400);
	assert c.split(SET_LEN).length == 3, "expected the presize and the cut";
}

test "presized push: a for-of push loop onto a fresh array is presized" {
	const c = emitted("const out: int32[] = []; for (const x of a) out.push(x * 3); return out;", true);
	assert !c.startsWith("error:"), c.slice(0, 400);
	assert c.split(SET_LEN).length == 3, "expected the presize and the cut";
}

test "presized push: a filter keeps the push loop" {
	const c = builtC("filtertoarray", "return a.values().filter((x) => x > 1).toArray();", true);
	assert !c.startsWith("error:"), c.slice(0, 400);
	assert !c.includes(SET_LEN), "a loop that pushes under a branch was presized";
}

test "presized push: a body that reads the array it builds keeps the push loop" {
	const c = emitted("const out: int32[] = []; for (const x of a) out.push(x + out.length); return out;", true);
	assert !c.startsWith("error:"), c.slice(0, 400);
	assert !c.includes(SET_LEN), "a loop that reads its result was presized";
}

const TWO_STEPS = "const out: int32[] = []; let i: int64 = 0; while (i < a.length) { out.push(a[i]); i++; i++; } return out;";

test "presized push: a while loop stepping its counter through a checked increment is presized" {
	const c = emitted("const out: int32[] = []; let i: int64 = 0; while (i < a.length) { out.push(a[i]); i++; } return out;", false);
	assert !c.startsWith("error:"), c.slice(0, 400);
	assert c.split(SET_LEN).length == 3, "expected the presize and the cut";
}

test "presized push: a counter stepped twice keeps the push loop" {
	const c = emitted(TWO_STEPS, true);
	assert !c.startsWith("error:"), c.slice(0, 400);
	assert !c.includes(SET_LEN), "a loop that steps its counter twice was presized";
}

test "presized push: a counter stepped twice through checked increments keeps the push loop" {
	const c = emitted(TWO_STEPS, false);
	assert !c.startsWith("error:"), c.slice(0, 400);
	assert !c.includes(SET_LEN), "a checked second step of the counter went unseen";
}

test "presized push: a loop inside a try keeps the push loop" {
	const c = emitted("const out: int32[] = []; try { for (const x of a) out.push(x); } catch (e) {} return out;", true);
	assert !c.startsWith("error:"), c.slice(0, 400);
	assert !c.includes(SET_LEN), "a loop whose partial result a catch can read was presized";
}

test "presized push: a checked build presizes too" {
	const c = builtC("checkedtoarray", "return a.values().map((x) => x * 2).toArray();", false);
	assert !c.startsWith("error:"), c.slice(0, 400);
	assert c.split(SET_LEN).length == 3, "a checked build kept the push loop";
}
