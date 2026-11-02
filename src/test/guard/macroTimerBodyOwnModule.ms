// A generic std body the macro engine instantiates is checked in the module that owns its symbol, the
// Raiser prelude's, not in a module of the same path the CLI build registered for the program.
//
// WHY A SUBPROCESS: only a CLI build registers the program's std modules beside the engine's prelude;
// an in-process compile does not, so it never meets the collision. The compiler under test is $MSC,
// else `./msc`.
//
// RED PRE-FIX: setTimeout throws "extension call '.toPairs' reached lowering without its resolved
// symbol", setInterval "instance 'orderedMapFill_…' has no retained type parameters". GREEN: both
// builds refuse with the module state the VM cannot read.

import { execFileResult, cwd, exit, env } from "std/process";
import { writeFile, ensureDir } from "std/fs";

const root = cwd();
const mscEnv = env.get("MSC");
const msc = mscEnv != "" ? mscEnv : `${root}/msc`;
const dir = `${root}/out/guardMacroTimerBodyOwnModule`;
ensureDir(dir);

let failed = 0;
for (const timer of ["setTimeout", "setInterval"]) {
	const file = `${dir}/${timer}.ms`;
	writeFile(file, `import { Node, NodeKind } from "std/meta";
export macro starts(node: Node): Node {
	const t = ${timer}((): void => {}, 0);
	return { kind: NodeKind.StringLiteral, line: node.line, column: node.column, value: "x" };
}
console.log(starts(0));
`);
	const r = execFileResult(msc, ["build", file, `--output=${dir}/${timer}`], dir);
	const text = r.output + r.errorOutput;
	if (r.exitCode == 0 || !text.contains("cannot evaluate 'timerNext' at comptime: symbol is mutable") || text.contains("internal")) {
		console.log(`GUARD-FAIL ${timer}: exit ${r.exitCode}: ${text.slice(0, 400)}`);
		failed = failed + 1;
	}
}

if (failed != 0) exit(1);
console.log("GUARD-OK");
