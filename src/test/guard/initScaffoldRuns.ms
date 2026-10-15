// `msc init` writes a project that `msc build` and `msc run` take as it is, with or without a file
// argument, whose first run prints the scaffold's greeting on C and on JS, and whose `main()` can
// leave a timer behind that still fires.
//
// WHY A SUBPROCESS: the observable is what a new user sees from `msc init` then `msc build` or
// `msc run`, which no in-process test reaches. The compiler under test is $MSC, else `./msc`.
//
// RED PRE-FIX: on 15b93cbba the runs exit 0 and print no greeting, because nothing called the
// scaffold's `main()`, and a file-less build stops with "error: build requires an input file",
// because the scaffold's build.ms names its entry `root`, a key the loader does not read. With the
// scaffold ending in `process.exit(main())`, a timer set inside `main()` never fires on either
// backend, because the exit skips the drain of pending work.
// GREEN POST-FIX: GUARD-OK.

import { execFileResult, cwd, exit, env } from "std/process";
import { removeAll, readFile, writeFile } from "std/fs";

const root = cwd();
const mscEnv = env.get("MSC");
const msc = mscEnv != "" ? mscEnv : `${root}/msc`;
const dir = `${root}/out/guardInitScaffoldRuns`;
const greeting = "hello, metascript!";

let failed = 0;

function check(args: string[], want: string): void {
	const r = execFileResult(msc, args, dir);
	if (r.exitCode != 0 || !r.output.includes(want)) {
		console.log(`GUARD-FAIL msc ${args.join(" ")}: exit ${r.exitCode}: ${r.output}${r.errorOutput}`);
		failed = failed + 1;
	}
}

removeAll(dir);
const init = execFileResult(msc, ["init", dir]);
if (init.exitCode != 0) {
	console.log(`GUARD-FAIL init: ${init.output}${init.errorOutput}`);
	exit(1);
}
check(["run", "--target=c", "src/index.ms"], greeting);
check(["run", "--target=js", "src/index.ms"], greeting);
check(["build"], "");
check(["run"], greeting);
check(["run", "--target=js"], greeting);

const entry = `${dir}/src/index.ms`;
const source = readFile(entry);
const greetingLine = `\tconsole.log("${greeting}");`;
if (!source.ok || !source.value.includes(greetingLine)) {
	console.log(`GUARD-FAIL ${entry} has no greeting line to set a timer beside`);
	exit(1);
}
writeFile(entry, source.value.replace(greetingLine, `\tsetTimeout((): void => { console.log("later"); }, 0);\n${greetingLine}`));
check(["run", "--target=c", "src/index.ms"], "later");
check(["run", "--target=js", "src/index.ms"], "later");
if (failed != 0) exit(1);
console.log("GUARD-OK");
