// Executable contract of std/process execFileResult on the native backend:
// structured arguments, working directory, both streams and exit status,
// observed through a real child that is this same program.
//
// Parent: <exe> parent <new private directory>
// The private directory must not exist yet; its parent must. The parent copies
// itself to a path with spaces inside it and spawns that copy as the child.
// Child: <copy> --child argv|status|cwd [arguments], never typed by hand.
// The last stdout line is `processContractTest: PASS <n> checks` or
// `processContractTest: FAIL <failed> of <n> checks`; details go to stderr.

import {
	argv,
	cwd,
	ExecFileResult,
	execFileResult,
	execPath,
	exit,
	platform,
} from "std/process";
import { writeStderr, writeStdout } from "std/io";
import { IoError } from "std/io/errors";
import {
	basename,
	chmod,
	copyFile,
	dirname,
	exists,
	fileSize,
	isAbsolute,
	isDir,
	isExecutable,
	join,
	mkdir,
	readFile,
	remove,
	resolve,
	rmdir,
	writeFile,
} from "std/fs";

const CHILD_FLAG = "--child";
const STATUS_EXIT_CODE: int32 = 7;
const MISSING_PROGRAM_ERRNO: int32 = 2;
const SENTINEL_NAME = "processContractSentinel.txt";
const SENTINEL_TOKEN = "cwd-sentinel-3f9a";
const STATUS_STDOUT = "status-out \u4e2d\n";
const STATUS_STDERR = "status-err \u00e9\n";
const ARGV_STDERR = "argv-err \u00e9\u{1F600}\n";

// Each value is one argument: spaces, a quote, an empty string, backslashes
// before a quote and at the end, non-ASCII, and shell metacharacters that no
// shell may see.
const SAMPLE_ARGS: string[] = [
	"plain",
	"two words",
	"",
	"say \"hi\" now",
	"trail\\",
	"C:\\Program Files\\x\\",
	"a\\\"b",
	"sp ace\\\\",
	"\u00e9\u4e2d\u{1F600}",
	"a&b|c<d>e^f%PATH%$HOME;*?!~#(){}'`",
	"--flag=a b",
];

// ===== Child =====

function argLines(items: string[]): string {
	let text = `count=${items.length}\n`;
	for (let i: int32 = 0; i < items.length; i += 1) {
		text += `[${i}]=<${items[i]}>\n`;
	}
	return text;
}

function childArgv(): void {
	const received: string[] = [];
	for (let i: int32 = 3; i < argv.length; i += 1) {
		received.push(argv[i]);
	}
	writeStdout(`exe=${basename(execPath)}\n` + argLines(received));
	writeStderr(ARGV_STDERR);
}

// The deliberate exit is the contract under test: a child that ends with a
// non-zero status after writing both streams.
function childStatus(): void {
	writeStdout(STATUS_STDOUT);
	writeStderr(STATUS_STDERR);
	exit(STATUS_EXIT_CODE);
}

function childCwd(sentinelName: string): void {
	if (!exists(sentinelName)) {
		writeStdout("present=false\n");
		return;
	}
	const content = readFile(sentinelName);
	if (content.ok) {
		writeStdout(`present=true\ncontent=${content.value}\n`);
	} else {
		writeStderr(`cannot read ${sentinelName}: ${content.error.message}\n`);
		exit(3);
	}
}

function runChild(): void {
	const scenario = argv.length > 2 ? argv[2] : "";
	if (scenario == "argv") {
		childArgv();
	} else if (scenario == "status") {
		childStatus();
	} else if (scenario == "cwd" && argv.length > 3) {
		childCwd(argv[3]);
	} else {
		writeStderr(`unknown child scenario: ${scenario}\n`);
		exit(2);
	}
}

// ===== Parent: counted checks =====

class Tally {
	count: int32 = 0;
	failed: int32 = 0;
}

function pass(tally: Tally): void {
	tally.count += 1;
}

function fail(tally: Tally, label: string, detail: string): void {
	tally.count += 1;
	tally.failed += 1;
	writeStderr(`FAIL ${label}: ${detail}\n`);
}

function described(text: string): string {
	return `<${text}> (${text.byteLength()} bytes)`;
}

function expectTrue(tally: Tally, condition: boolean, label: string): void {
	if (condition) {
		pass(tally);
	} else {
		fail(tally, label, "expected true");
	}
}

function expectInt(
	tally: Tally,
	actual: int32,
	expected: int32,
	label: string,
): void {
	if (actual == expected) {
		pass(tally);
	} else {
		fail(tally, label, `expected ${expected}, got ${actual}`);
	}
}

function expectText(
	tally: Tally,
	actual: string,
	expected: string,
	label: string,
): void {
	if (actual == expected) {
		pass(tally);
	} else {
		fail(
			tally,
			label,
			`expected ${described(expected)}, got ${described(actual)}`,
		);
	}
}

function expectOk(
	tally: Tally,
	result: Result<void, IoError>,
	label: string,
): void {
	if (!result.ok) {
		fail(tally, label, result.error.message);
		return;
	}
	pass(tally);
}

// A child that ran: five checks on status, no start error, nothing lost.
function expectRan(
	tally: Tally,
	result: ExecFileResult,
	exitCode: int32,
	label: string,
): void {
	expectTrue(tally, result.started, `${label}: started`);
	expectTrue(tally, result.pipeOk, `${label}: pipeOk`);
	expectInt(tally, result.exitCode, exitCode, `${label}: exitCode`);
	expectInt(tally, result.signal, 0, `${label}: signal`);
	expectInt(tally, result.startErrno, 0, `${label}: startErrno`);
}

// ===== Parent: private artifacts =====

struct Layout {
	privateDir: string;
	binDir: string;
	cwdDir: string;
	childName: string;
	childPath: string;
	sentinelPath: string;
	missingPath: string;
}

function layoutOf(privateDir: string): Layout {
	const binDir = join(privateDir, "owned bin dir");
	const cwdDir = join(privateDir, "cwd dir");
	const childName = platform == "windows"
		? "process contract child.exe"
		: "process contract child";
	return {
		privateDir,
		binDir,
		cwdDir,
		childName,
		childPath: join(binDir, childName),
		sentinelPath: join(cwdDir, SENTINEL_NAME),
		missingPath: join(binDir, "missing child"),
	};
}

// 12 checks. Refuses an existing private directory before touching anything.
function prepare(tally: Tally, layout: Layout): boolean {
	expectTrue(tally, isAbsolute(execPath), "execPath is absolute");
	expectTrue(
		tally,
		!exists(layout.privateDir),
		"private directory does not exist yet",
	);
	expectTrue(
		tally,
		isDir(dirname(layout.privateDir)),
		"private directory parent exists",
	);
	if (tally.failed > 0) return false;

	expectOk(tally, mkdir(layout.privateDir), "mkdir private directory");
	expectOk(tally, mkdir(layout.binDir), "mkdir bin directory");
	expectOk(tally, mkdir(layout.cwdDir), "mkdir cwd directory");
	if (tally.failed > 0) return false;

	expectOk(tally, copyFile(execPath, layout.childPath), "copy self");
	let modeError = "";
	if (platform != "windows") {
		const mode = chmod(layout.childPath, 493);
		if (!mode.ok) modeError = mode.error.message;
	}
	expectText(tally, modeError, "", "chmod copy 0755");
	expectTrue(tally, isExecutable(layout.childPath), "copy is executable");
	expectTrue(
		tally,
		fileSize(layout.childPath) == fileSize(execPath),
		"copy has the size of the original",
	);
	expectOk(
		tally,
		writeFile(layout.sentinelPath, SENTINEL_TOKEN),
		"write sentinel",
	);
	expectTrue(
		tally,
		!exists(SENTINEL_NAME),
		"sentinel name is absent from the parent cwd",
	);
	return tally.failed == 0;
}

// ===== Parent: scenarios =====

// 7 checks: structured arguments, both streams at exit 0, inherited cwd.
function checkArguments(tally: Tally, layout: Layout): void {
	const args = [CHILD_FLAG, "argv"];
	for (const sample of SAMPLE_ARGS) {
		args.push(sample);
	}
	const result = execFileResult(layout.childPath, args);
	expectRan(tally, result, 0, "arguments");
	expectText(
		tally,
		result.output,
		`exe=${layout.childName}\n` + argLines(SAMPLE_ARGS),
		"arguments: stdout",
	);
	expectText(tally, result.errorOutput, ARGV_STDERR, "arguments: stderr");
}

// 7 checks: both streams and the status of a child that exits with 7.
function checkStatus(tally: Tally, layout: Layout): void {
	const result = execFileResult(layout.childPath, [CHILD_FLAG, "status"]);
	expectRan(tally, result, STATUS_EXIT_CODE, "status");
	expectText(tally, result.output, STATUS_STDOUT, "status: stdout");
	expectText(tally, result.errorOutput, STATUS_STDERR, "status: stderr");
}

// 15 checks: the child sees the given directory, and only when it is given;
// the parent's own cwd stays put.
function checkWorkingDirectory(
	tally: Tally,
	layout: Layout,
	parentCwd: string,
): void {
	const args = [CHILD_FLAG, "cwd", SENTINEL_NAME];
	const inside = execFileResult(layout.childPath, args, layout.cwdDir);
	expectRan(tally, inside, 0, "cwd given");
	expectText(
		tally,
		inside.output,
		`present=true\ncontent=${SENTINEL_TOKEN}\n`,
		"cwd given: stdout",
	);
	expectText(tally, inside.errorOutput, "", "cwd given: stderr");

	const inherited = execFileResult(layout.childPath, args);
	expectRan(tally, inherited, 0, "cwd inherited");
	expectText(
		tally,
		inherited.output,
		"present=false\n",
		"cwd inherited: stdout",
	);
	expectText(tally, inherited.errorOutput, "", "cwd inherited: stderr");

	expectText(tally, cwd(), parentCwd, "parent cwd is unchanged");
}

// 6 checks: a program that does not exist never starts.
function checkMissingExecutable(tally: Tally, layout: Layout): void {
	expectTrue(tally, !exists(layout.missingPath), "missing path is absent");
	const result = execFileResult(layout.missingPath, [CHILD_FLAG, "argv"]);
	expectTrue(tally, !result.started, "missing: started is false");
	expectInt(
		tally,
		result.startErrno,
		MISSING_PROGRAM_ERRNO,
		"missing: startErrno",
	);
	expectInt(tally, result.exitCode, 0, "missing: exitCode");
	expectText(tally, result.output, "", "missing: stdout");
	expectText(tally, result.errorOutput, "", "missing: stderr");
}

// 5 checks, only when every earlier check passed: removes exactly the files
// and directories this run made, children before parents, never a tree.
function cleanUp(tally: Tally, layout: Layout): void {
	expectOk(tally, remove(layout.childPath), "remove child copy");
	expectOk(tally, remove(layout.sentinelPath), "remove sentinel");
	expectOk(tally, rmdir(layout.cwdDir), "rmdir cwd directory");
	expectOk(tally, rmdir(layout.binDir), "rmdir bin directory");
	expectOk(tally, rmdir(layout.privateDir), "rmdir private directory");
}

function runParent(privateArgument: string): void {
	const tally = new Tally();
	const parentCwd = cwd();
	const layout = layoutOf(resolve(privateArgument, parentCwd));
	if (prepare(tally, layout)) {
		checkArguments(tally, layout);
		checkStatus(tally, layout);
		checkWorkingDirectory(tally, layout, parentCwd);
		checkMissingExecutable(tally, layout);
	}
	if (tally.failed == 0) {
		cleanUp(tally, layout);
	}
	if (tally.failed == 0) {
		writeStdout(`processContractTest: PASS ${tally.count} checks\n`);
		return;
	}
	writeStderr(`artifacts preserved: ${layout.privateDir}\n`);
	writeStdout(
		`processContractTest: FAIL ${tally.failed} of ${tally.count} checks\n`,
	);
	exit(1);
}

when (!testBuild) {
	if (argv.length > 1 && argv[1] == CHILD_FLAG) {
		runChild();
	} else if (argv.length > 2 && argv[1] == "parent") {
		runParent(argv[2]);
	} else {
		writeStderr("usage: processContractTest parent <new directory>\n");
		exit(2);
	}
}
