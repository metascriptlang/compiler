// @skip-js: the streaming child-process API is native/Raiser-only
// @stdout: Child environment contracts OK
import {
	argv, env, execPath, execFileResult, platform, spawn, SpawnOptions,
	ChildStream, ProcessErrorKind,
} from "std/process";
import { join, dirname, basename, mkdir, removeAll } from "std/fs";

let checks: int32 = 0;
function check(condition: boolean, label: string): void {
	if (!condition) { throw new Error(label); }
	checks += 1;
}

function collect(
	file: string, args: string[], options: SpawnOptions = {},
): string {
	const started = spawn(file, args, options);
	if (!started.ok) { throw new Error(started.error.message); }
	const child = started.value;
	child.closeStdin();
	let output = "";
	for (let i: int32 = 0; i < 16; i += 1) {
		const got = child.read(ChildStream.Stdout, 1000);
		if (!got.ok) { throw new Error(got.error.message); }
		output += got.value.data;
		if (got.value.ended) { break; }
	}
	const errors = child.takeStderr();
	const status = child.wait(1000);
	child.close();
	if (!status.ok || status.value.code != 0 || status.value.signal != 0 ||
		errors != "") { throw new Error("environment child failed"); }
	return output;
}

const found = execFileResult("node", ["-p", "process.execPath"]);
if (!found.started || found.exitCode != 0 || found.errorOutput != "") {
	throw new Error("Node oracle discovery failed");
}
const node = found.output.trim();
function query(code: string, options: SpawnOptions = {}): string {
	return collect(node, ["-e", code], options);
}

function cellKey(): int64 {
	const text = execPath + "|" + argv.join("|");
	let hash: int64 = 0;
	for (let i: int32 = 0; i < text.length; i += 1) {
		hash = (hash * 31 + (text.charCodeAt(i) as int64)) % 1000000007;
	}
	return hash;
}
const temp = platform == "windows" ? env.get("TEMP") :
	(env.get("TMPDIR") != "" ? env.get("TMPDIR") : "/tmp");
const dir = join(temp, "msChildEnvironment" + String(cellKey()));
const created = mkdir(dir);
if (!created.ok) {
	throw new Error("could not create exclusive child fixture");
}
const snapshot = "process.stdout.write(process.env.PATH + '|' + " +
	"process.env.HOME)";
const before = query(snapshot);
check(query("process.stdout.write('default')") == "default", "default spawn");
check(query("process.stdout.write(process.env.MS_TC_ONLY + '|' + " +
	"process.env.MS_TC_EMPTY + '|' + Object.hasOwn(process.env,'HOME'))", {
	env: { MS_TC_ONLY: "private", MS_TC_EMPTY: "" },
}) == "private||false", "literal map replaces parent");
const emptyExpected = platform == "windows" ? "false|true" : "false|false";
check(query("process.stdout.write(Object.hasOwn(process.env,'HOME') + " +
	"'|' + Object.hasOwn(process.env,'PATH'))", {
	env: new Map<string, string>(),
}) == emptyExpected, "empty map is not absent");
check(query("process.stdout.write(String(process.env.PATH === ''))", {
	env: { PATH: "" },
}) == "true", "explicit empty PATH");
check(query("process.stdout.write(process.env.MS_TC_VALUE)", {
	env: { MS_TC_VALUE: "é🚀" },
}) == "é🚀", "Unicode scalar value");
check(query("process.stdout.write(String(" +
	"process.env.MS_TC_VALUE.codePointAt(0)))", {
	env: { MS_TC_VALUE: "\uD800" },
}) == "65533", "lone value replaced once");
const loneKey = new Map<string, string>();
loneKey.set("\uD801", "key");
check(query("process.stdout.write(process.env['\\uFFFD'])", {
	env: loneKey,
}) == "key", "lone key replaced once");
const sharpExpected = platform == "windows" ? "plain|false" : "plain|true";
check(query("process.stdout.write(process.env.STRASSE + '|' + " +
	"Object.hasOwn(process.env,'straße'))", {
	env: { "straße": "sharp", STRASSE: "plain" },
}) == sharpExpected, "platform key equivalence");
if (platform == "windows") {
	check(query("process.stdout.write(process.env.MS_DUP)", {
		env: { ms_dup: "bad\0value", MS_DUP: "keep" },
	}) == "keep", "discarded duplicate not validated");
} else {
	const loser = spawn(node, [], {
		env: { ms_dup: "bad\0value", MS_DUP: "keep" },
	});
	check(!loser.ok && loser.error.message.endsWith(" EINVAL"),
		"distinct POSIX value still validated");
}
const nulKey = new Map<string, string>();
nulKey.set("bad\0key", "value");
const badKey = spawn(node, [], { env: nulKey });
check(!badKey.ok && badKey.error.message.endsWith(" EINVAL"), "NUL key");
const badValue = spawn(node, [], { env: { MS_BAD: "bad\0value" } });
check(!badValue.ok && badValue.error.message.endsWith(" EINVAL"), "NUL value");
check(collect(basename(node), ["-e", "process.stdout.write('path')"], {
	cwd: dir, env: { PATH: dirname(node) },
}) == "path", "child PATH used");
const noPath = spawn(basename(node), [], { cwd: dir, env: { PATH: "" } });
check(!noPath.ok && noPath.error.kind == ProcessErrorKind.NotFound,
	"empty child PATH does not search parent PATH");
check(query("process.stdout.write(" +
	"require('node:path').basename(process.cwd()))", {
	cwd: dir, env: {},
}) == basename(dir), "per-child cwd");

if (platform == "windows") {
	check(query("process.stdout.write(process.env.A)", {
		env: { "A=B": "payload" },
	}) == "B=payload", "equals inside name follows native separator");
	const emptyName = new Map<string, string>();
	emptyName.set("", "payload");
	const emptyRefused = spawn(node, [], { env: emptyName });
	check(!emptyRefused.ok && emptyRefused.error.message.endsWith(" EINVAL"),
		"empty name refused by Windows");
	const drive = new Map<string, string>();
	drive.set("=Z:", "C:\\");
	check(query("process.stdout.write('drive')", { env: drive }) == "drive",
		"drive environment name");
	const collisionTwo = new Map<string, string>();
	collisionTwo.set("\uD801", "second");
	collisionTwo.set("\uD800", "first");
	const winner = "process.stdout.write(process.env['\\uFFFD'])";
	check(query(winner, { env: collisionTwo }) == "second",
		"two encoded key collisions");
	const collisionThree = new Map<string, string>();
	collisionThree.set("\uD801", "second");
	collisionThree.set("\uFFFD", "literal");
	collisionThree.set("\uD800", "first");
	check(query(winner, { env: collisionThree }) == "second",
		"three encoded key collisions");
	const separated = new Map<string, string>();
	separated.set("\uD800", "first");
	separated.set("A", "a");
	separated.set("\uD801", "second");
	separated.set("Z", "z");
	separated.set("\uFFFD", "literal");
	check(query(winner, { env: separated }) == "second",
		"encoded collisions with other keys");
}
check(query(snapshot) == before, "parent selected environment unchanged");
check(removeAll(dir).ok, "owned successful fixture cleanup");
if (checks != (platform == "windows" ? 22 : 16)) {
	throw new Error("child environment case count changed");
}
console.log("Child environment contracts OK");
