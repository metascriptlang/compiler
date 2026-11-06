// A @comptime block and a macro run std/process spawning on the compiling host on every native build:
// exec and execFileCapture return the child's output, and a program that never starts fails with its errno, not ENOSYS.
// @stdout: hi | macro-ok | missing=true
// @xfail(js): a JS build compiles the .jms body of exec and execFileCapture for the macro VM (inbox 2026-10-19-macro-on-js-runs-the-jms-variant-of-its-imports)
// @xfail(esm): the same JS gap as @xfail(js)

import { Node, NodeKind } from "std/meta";
import { exec, execFileCapture } from "std/process";

const shell = @comptime {
	const r = exec("echo hi");
	return r.ok ? r.value.trim() : "fail";
};

macro captured(): Node {
	const out = execFileCapture("printf", ["%s", "macro-ok"]);
	return { kind: NodeKind.StringLiteral, line: 1, column: 1, value: out.ok ? out.value : "fail" };
}

macro neverStarts(): Node {
	const r = execFileCapture("/nonexistent/mscorpus-no-such-program");
	return { kind: NodeKind.StringLiteral, line: 1, column: 1, value: `missing=${!r.ok && !r.error.message.includes("ENOSYS")}` };
}

console.log(`${shell} | ${captured()} | ${neverStarts()}`);
