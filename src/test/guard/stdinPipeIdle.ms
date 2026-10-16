// nim-guard: `stdinHasData()` on an open pipe that holds no bytes is false. The
// LSP server drains queued messages while it is true; a pipe that always reads
// ready parks it in a blocking read and no reply leaves before the client's EOF.
//
// WHY A SUBPROCESS: the pipe must stay open and empty while the child asks. Keep the
// writer waiting for the child's answer, not a timer: EOF reads ready, and a timed
// writer exits first on a loaded host. The child is built by $MSC, else `./msc`.
//
// RED PRE-FIX: Windows prints STDIN-IDLE-READY (WaitForSingleObject on a pipe).
// GREEN POST-FIX: every host prints STDIN-IDLE-EMPTY.

import { exec, execFileCapture, cwd, exit, env, platform } from "std/process";
import { ensureDir } from "std/fs";

const root = cwd();
const mscEnv = env.get("MSC");
const msc = mscEnv != "" ? mscEnv : `${root}/msc`;
const probe = `${root}/src/test/guard/fixtures/stdinPipeIdleProbe.ms`;
const isWin = platform == "windows";
const dir = `${root}/out/stdinPipeIdle`;
ensureDir(dir);
const bin = isWin ? `${dir}/stdinPipeIdleProbe.exe` : `${dir}/stdinPipeIdleProbe`;

const built = execFileCapture(msc, ["build", probe, `--output=${bin}`]);
if (!built.ok) {
	console.log(`GUARD-FAIL build: ${built.error.output}${built.error.errorOutput}`);
	exit(1);
}

const answered = `${dir}/answered`;
const runner = isWin ? bin.replaceAll("/", "\\") : bin;
const pipeline = isWin
	? `ping -n 3 127.0.0.1 >nul | "${runner}"`
	: `rm -f "${answered}"; while [ ! -e "${answered}" ]; do sleep 0.05; done | { "${runner}"; : > "${answered}"; }`;
const r = exec(pipeline);
const out = r.ok ? r.value : r.error.output + r.error.errorOutput;
if (!out.includes("STDIN-IDLE-EMPTY")) {
	console.log(`GUARD-FAIL: ${out}`);
	exit(1);
}
console.log("GUARD-OK");
