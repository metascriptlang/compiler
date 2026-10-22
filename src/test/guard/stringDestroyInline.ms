// A string destroy is inline code at every call site, so a destroy of a moved-from local or of a
// literal folds away without LTO instead of calling into the runtime. Scope cleanup still emits
// `msStringDecref` after `msStringWasMoved`; only an inline body lets the C compiler see that the
// value is empty or literal and drop the call. This builds two programs with --lto=off, one that
// returns a local string (plain and behind a throwing check) and one that reads a literal held in
// a local, each at --danger and --release, and reads the linked symbol table: no copy of
// `msStringDestroy` may remain, because every caller inlines it.
//
// WHY A SUBPROCESS: the observable is the linked binary's symbols. The compiler under test is
// $MSC, else `./msc`. A host without `nm` prints GUARD-SKIP, which the runner reports as unscored.
//
// RED MEANS: `msStringDestroy` is an out-of-line function again (its body moved back into a .c
// file), or some caller stopped inlining it.
// RED PRE-FIX: every build links `T _msStringDestroy` (macOS arm64, 2026-10-23). GREEN POST-FIX: GUARD-OK.

import { execFileResult, cwd, exit, env, cmdExists } from "std/process";
import { writeFile, ensureDir, removeAll, exists } from "std/fs";

const root = cwd();
const mscEnv = env.get("MSC");
const msc = mscEnv != "" ? mscEnv : `${root}/msc`;
const dir = `${root}/out/guardStringDestroyInline`;

const PROGRAMS = [
	{
		name: "movedResult",
		source: `@noinline
function build(n: int32): string {
	const result = "x".repeat(n);
	return result;
}

@noinline
function checked(n: int32): string {
	const result = "x".repeat(n);
	if (result.length != n) throw new Error("short");
	return result;
}

console.log(build(3), checked(2));
`,
	},
	{
		name: "literalLocal",
		source: `@noinline
function digitAt(index: int32): string {
	const digits = "0123456789abcdef";
	return digits.charAt(index);
}

console.log(digitAt(3), digitAt(12));
`,
	},
];

const MODES = ["--danger", "--release"];

let failed = 0;

if (!cmdExists("nm")) {
	console.log("GUARD-SKIP nm is not on PATH");
	exit(0);
}

removeAll(dir);
ensureDir(dir);

for (const program of PROGRAMS) {
	writeFile(`${dir}/${program.name}.ms`, program.source);
	for (const mode of MODES) {
		const binary = `${dir}/${program.name}${mode.replace("--", "-")}`;
		const build = execFileResult(msc, ["build", `${program.name}.ms`, "--gc=drc", mode, "--lto=off", `--output=${binary}`], dir);
		if (build.exitCode != 0) {
			console.log(`GUARD-FAIL ${program.name} ${mode}: build failed\n${build.output}${build.errorOutput}`);
			failed = failed + 1;
			continue;
		}
		const path = exists(`${binary}.exe`) ? `${binary}.exe` : binary;
		const symbols = execFileResult("nm", [path]);
		for (const line of symbols.output.split("\n")) {
			const fields = line.trim().split(" ");
			const symbol = fields[fields.length - 1];
			if (symbol == "msStringDestroy" || symbol == "_msStringDestroy") {
				console.log(`GUARD-FAIL ${program.name} ${mode}: links an out-of-line copy (${line.trim()})`);
				failed = failed + 1;
			}
		}
	}
}

if (failed != 0) exit(1);
console.log("GUARD-OK");
