// E2E C: a loop that pushes once per step onto a fresh array presizes it and writes by index under --danger
// (NIM-REF TR-41); runtime results across grow, shrink and raise: corpus presizedPushBuild.

import { compileToC } from "../helpers";
import { hostTargetInfo } from "../../checker/types";
import { execFileResult, cwd, env } from "std/process";
import { writeFile, ensureDir, removeAll, readFile, readDir } from "std/fs";

function emitted(body: string, danger: boolean): string {
	const c = compileToC(`
function f(a: int32[]): int32[] {
	${body}
}
const xs: int32[] = [1, 2, 3];
console.log(f(xs).length);`, hostTargetInfo(), false, true, danger);
	return c.ok ? c.value : "error: " + c.error;
}

// The std chain bodies are offered to the inliner only by a whole-program build.
function builtC(name: string, body: string, danger: boolean): string {
	const root = cwd();
	const mscEnv = env.get("MSC");
	const msc = mscEnv != "" ? mscEnv : `${root}/msc`;
	const dir = `${root}/out/presizedPushEmit/${name}`;
	removeAll(dir);
	ensureDir(dir);
	writeFile(`${dir}/${name}.ms`, `function f(a: int32[]): int32[] {\n\t${body}\n}\nconst xs: int32[] = [1, 2, 3];\nconsole.log(f(xs).length);\n`);
	const args = ["build", `${dir}/${name}.ms`, "--emit=c", "--output=prog"];
	if (danger) args.push("--danger");
	const r = execFileResult(msc, args, dir);
	if (r.exitCode != 0) return "error: " + r.errorOutput;
	for (const mode of readDir(`${dir}/out`)) {
		for (const file of readDir(`${dir}/out/${mode}`)) {
			if (file == `${name}Oms.c` || file.endsWith(`Z${name}Oms.c`)) {
				const text = readFile(`${dir}/out/${mode}/${file}`);
				return text.ok ? text.value : "error: unreadable " + file;
			}
		}
	}
	return "error: no C unit for " + name;
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

test "presized push: a loop inside a try keeps the push loop" {
	const c = emitted("const out: int32[] = []; try { for (const x of a) out.push(x); } catch (e) {} return out;", true);
	assert !c.startsWith("error:"), c.slice(0, 400);
	assert !c.includes(SET_LEN), "a loop whose partial result a catch can read was presized";
}

test "presized push: a checked build keeps the push loop" {
	const c = builtC("checkedtoarray", "return a.values().map((x) => x * 2).toArray();", false);
	assert !c.startsWith("error:"), c.slice(0, 400);
	assert !c.includes(SET_LEN), "a checked build was rewritten";
}
