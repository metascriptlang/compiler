// @skip-js: the streaming child-process API is native/Raiser-only
// @stdout: Child raw bytes: 6 cases OK
import {
	spawn, execFileResult, ChildProcess, ChildStream,
} from "std/process";

function byteList(bytes: Readonly<Span<uint8>>): string {
	let text = "";
	for (let i: int64 = 0; i < bytes.length; i += 1) {
		if (i != 0) { text += ","; }
		text += String(bytes[i]);
	}
	return text;
}

function collect(child: ChildProcess, stream: ChildStream): uint8[] {
	const bytes: uint8[] = [];
	for (let i: int32 = 0; i < 128; i += 1) {
		const got = child.readBytes(stream, 1000);
		if (!got.ok) { throw new Error(got.error.message); }
		for (const byte of got.value.data) { bytes.push(byte); }
		if (got.value.ended) { return bytes; }
	}
	throw new Error("child raw-byte stream did not end");
}

function same(
	actual: Readonly<Span<uint8>>, expected: Readonly<Span<uint8>>,
	label: string,
): void {
	if (actual.length != expected.length) {
		throw new Error(label + ": byte count changed " +
			String(actual.length) + " != " + String(expected.length));
	}
	for (let i: int64 = 0; i < expected.length; i += 1) {
		if (actual[i] != expected[i]) {
			throw new Error(label + ": byte differs at " + String(i));
		}
	}
}

const discovered = execFileResult("node", ["-p", "process.execPath"]);
if (!discovered.started || discovered.exitCode != 0 ||
	discovered.errorOutput != "") {
	throw new Error("Node byte fixture discovery failed: " +
		String(discovered.exitCode));
}
const node = discovered.output.trim();
let cases: int32 = 0;
function check(
	out: Readonly<Span<uint8>>, errors: Readonly<Span<uint8>>,
): void {
	const code = "process.stdout.write(Buffer.from([" + byteList(out) +
		"]));process.stderr.write(Buffer.from([" + byteList(errors) + "]));";
	const started = spawn(node, ["-e", code]);
	if (!started.ok) { throw new Error(started.error.message); }
	const child = started.value;
	child.closeStdin();
	const stdout = collect(child, ChildStream.Stdout);
	const stderr = collect(child, ChildStream.Stderr);
	const status = child.wait(1000);
	child.close();
	if (!status.ok) { throw new Error(status.error.message); }
	if (status.value.code != 0 || status.value.signal != 0) {
		throw new Error("raw byte fixture child failed: code=" +
			String(status.value.code) + " signal=" + String(status.value.signal));
	}
	same(stdout, out, "stdout");
	same(stderr, errors, "stderr");
	cases += 1;
}

const none: uint8[] = [];
const invalid: uint8[] = [0, 255, 195, 40, 0, 128, 10, 13, 127];
const all: uint8[] = [];
const reversed: uint8[] = [];
for (let i: int32 = 0; i < 256; i += 1) {
	all.push(i as uint8);
	reversed.push((255 - i) as uint8);
}
const partial: uint8[] = [240, 159];
const surrogate: uint8[] = [237, 160, 128];
check(none, none);
check(invalid, none);
check(none, invalid);
check(all, reversed);
check(partial, surrogate);
check(surrogate, partial);
if (cases != 6) { throw new Error("raw byte fixture count changed"); }
console.log("Child raw bytes: 6 cases OK");
