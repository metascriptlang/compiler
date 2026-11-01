import {
	captureToolBytes, captureToolUtf8, ToolTextResult,
} from "./processCapture";
import { cwd, env, execFileResult, platform, SpawnOptions } from "std/process";

let checks: int32 = 0;
function check(condition: boolean, label: string): void {
	if (!condition) { throw new Error(label); }
	checks += 1;
}

function run(
	node: string,
	source: string,
	args: string[] = [],
	options: SpawnOptions = {},
): ToolTextResult {
	const done = captureToolUtf8(node, ["-e", source, "--", ...args], options);
	if (!done.ok) { throw new Error(done.error); }
	return done.value;
}

function expect(
	actual: ToolTextResult, code: int64, out: string, errors: string,
	label: string,
): void {
	check(actual.returnCode == code,
		label + ": return code " + String(actual.returnCode));
	check(actual.output == out, label + ": stdout differs");
	check(actual.errorOutput == errors, label + ": stderr differs");
}

function main(): void {
	const discovered = execFileResult("node", ["-p", "process.execPath"]);
	if (!discovered.started || discovered.exitCode != 0 ||
		discovered.errorOutput != "") {
		throw new Error("Node capture fixture discovery failed: " +
			String(discovered.exitCode));
	}
	const node = discovered.output.trim();
	const before = env.get("HOME") + "|" + env.get("PATH");

	expect(run(node, ""), 0, "", "", "empty streams");
	expect(run(node, "process.stdout.write('out\\r\\na\\rb\\n\\u0000é🚀');" +
		"process.stderr.write('err\\r\\nc\\r');"),
		0, "out\na\nb\n\0é🚀", "err\nc\n", "universal newlines and Unicode");
	const args = ["space here", "", "a&b|c", "\"quote\"", "trailing\\", "é🚀"];
	expect(run(node, "process.stdout.write(process.argv.slice(1).join('|'))",
		args), 0, args.join("|"), "", "literal argv without shell");
	expect(run(node, "process.stdout.write(String(require('node:fs')." +
		"readFileSync(0).length))"), 0, "0", "", "stdin closed");
	expect(run(node, "process.stdout.write('out');process.stderr.write('err');" +
		"process.exitCode=7"), 7, "out", "err", "nonzero retains streams");
	expect(run(node, "process.stdout.write(process.env.MS_TC_CAPTURE + '|' + " +
		"Object.hasOwn(process.env,'HOME'))", [], {
		env: { MS_TC_CAPTURE: "private" },
	}), 0, "private|false", "", "private environment");
	expect(run(node, "process.stdout.write(process.cwd()." +
		"split(String.fromCharCode(92)).join('/'))", [], { cwd: "." }),
		0, cwd().replaceAll("\\", "/"), "", "child cwd");
	expect(run(node, "process.stdout.write(Buffer.from([240,159]));" +
		"setTimeout(()=>process.stdout.write(Buffer.from([154,128])),10)"),
		0, "🚀", "", "decode only after complete byte capture");
	expect(run(node, "require('node:fs').closeSync(1);" +
		"require('node:fs').closeSync(2);setTimeout(()=>process.exit(7),1200)"),
		7, "", "", "wait after both pipes close");
	expect(run(node, "process.stdout.write(Buffer.from([239,191,189]))"),
		0, "�", "", "valid replacement scalar is preserved");

	const badOut = captureToolUtf8(node, ["-e",
		"process.stdout.write(Buffer.from([255]))"]);
	check(!badOut.ok && badOut.error.indexOf("stdout is not UTF-8") >= 0,
		"malformed stdout refused instead of repaired");
	const badErr = captureToolUtf8(node, ["-e",
		"process.stderr.write(Buffer.from([195,40]))"]);
	check(!badErr.ok && badErr.error.indexOf("stderr is not UTF-8") >= 0,
		"malformed stderr refused instead of repaired");
	const surrogate = captureToolUtf8(node, ["-e",
		"process.stdout.write(Buffer.from([237,160,128]))"]);
	check(!surrogate.ok && surrogate.error.indexOf("stdout is not UTF-8") >= 0,
		"surrogate encoding is not UTF-8");
	const missing = captureToolUtf8("mscMissingCaptureExecutable-fc317c", []);
	check(!missing.ok && missing.error.indexOf("ENOENT") >= 0,
		"missing executable reports start failure");

	const bytes = captureToolBytes(node, ["-e",
		"process.stdout.write(Buffer.from(Array.from({length:256},(_,i)=>i)));" +
		"process.stderr.write(Buffer.from(Array.from({length:256}," +
		"(_,i)=>255-i)))"]);
	if (!bytes.ok) { throw new Error(bytes.error); }
	check(bytes.value.returnCode == 0, "raw capture child status");
	let exactOut = bytes.value.output.length == 256;
	let exactErr = bytes.value.errorOutput.length == 256;
	if (exactOut && exactErr) {
		for (let i: int32 = 0; i < 256; i += 1) {
			exactOut = exactOut && bytes.value.output[i] == i;
			exactErr = exactErr && bytes.value.errorOutput[i] == 255 - i;
		}
	}
	check(exactOut, "raw stdout all256");
	check(exactErr, "raw stderr all256");
	check(env.get("HOME") + "|" + env.get("PATH") == before,
		"parent environment unchanged");
	if (platform == "windows") {
		expect(run(node, "process.exit(2147483649)"), 2147483649, "", "",
			"Windows DWORD status is not negative signal status");
	} else {
		expect(run(node, "process.kill(process.pid,'SIGTERM')"), -15, "", "",
			"POSIX signal has subprocess-style negative return code");
	}
	if (checks != 41) { throw new Error("process capture case count changed"); }
	console.log("Process capture: 41 checks OK");
}

when (!testBuild) { main(); }
