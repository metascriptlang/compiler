// A macro reads every status field of execFileResult, the cwd argument included, the same on every target:
// a child that exits non-zero, a child run in another directory, and a program that never starts.
// @stdout: exit=3 started=true pipe=true signal=0 | moved=true | never=false errno=true

import { Node, NodeKind } from "std/meta";
import { execFileResult } from "std/process";

macro exitStatus(): Node {
	const r = execFileResult("sh", ["-c", "exit 3"]);
	return { kind: NodeKind.StringLiteral, line: 1, column: 1, value: `exit=${r.exitCode} started=${r.started} pipe=${r.pipeOk} signal=${r.signal}` };
}

macro inDirectory(): Node {
	const here = execFileResult("sh", ["-c", "pwd"]);
	const root = execFileResult("sh", ["-c", "pwd"], "/");
	return { kind: NodeKind.StringLiteral, line: 1, column: 1, value: `moved=${root.output.trim() != here.output.trim()}` };
}

macro neverStarts(): Node {
	const r = execFileResult("/nonexistent/mscorpus-no-such-program");
	return { kind: NodeKind.StringLiteral, line: 1, column: 1, value: `never=${r.started} errno=${r.startErrno != 0}` };
}

console.log(`${exitStatus()} | ${inDirectory()} | ${neverStarts()}`);
