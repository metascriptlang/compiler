// A spawned task that calls import() is judged by the functions it calls through the namespace,
// not refused for the import() call itself: a call to a pure export compiles quiet, and a call to
// an export that writes module state is reported naming that state, in the thunk and one routine deeper.

import { execFileResult, cwd, env, exit } from "std/process";

const V0 = "module state crosses threads";

function requireCondition(ok: boolean, detail: string): void {
	if (!ok) {
		console.log("GUARD-FAIL " + detail);
		exit(1);
	}
}

function checkOutput(msc: string, file: string): string {
	const r = execFileResult(msc, ["check", file]);
	return r.output + r.errorOutput;
}

function countOf(text: string, needle: string): int32 {
	let n: int32 = 0;
	let at = text.indexOf(needle, 0);
	while (at >= 0) {
		n += 1;
		at = text.indexOf(needle, at + needle.length);
	}
	return n;
}

const root = cwd();
const mscEnv = env.get("MSC");
const msc = mscEnv != "" ? mscEnv : root + "/msc";
const dir = root + "/src/test/guard/fixtures/spawnImport";

const pure = checkOutput(msc, dir + "/importsPure.ms");
requireCondition(countOf(pure, V0) == 0, "a task importing a pure module was refused\n" + pure);

const state = checkOutput(msc, dir + "/importsState.ms");
requireCondition(countOf(state, "uses module-level 'hits'") == 2, "both tasks reaching 'hits' must be reported\n" + state);
requireCondition(countOf(state, "calls a function value") == 0, "import() was taken for a function value\n" + state);
console.log("GUARD-OK");
