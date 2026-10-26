// guard: an Arc argument is counted before its message reaches the mailbox
//
// INVARIANT (ULTRALOCK M7): the actor message setter takes the Arc's shared count before the
//   send publishes the message, for a SEND and a CALL, for an Arc in the first and in a later
//   argument slot. The runtime half (the count is atomic and the TSan run is clean) is
//   actorArcPublishRaceFree.ms; this pins the emitted order.
//
// WHY A SUBPROCESS: the observable is the emitted C of the sending wrapper. The compiler under
//   test is $MSC, else `./msc`; the C is read from `--emit=c`.
//
// RED MEANS: the wrapper stores the Arc with a setter that takes no count, or sends before the
//   counting setter, so the receiver can drop the last count while the sender still holds it.

import { execFileResult, cwd, exit, env } from "std/process";
import { writeFile, ensureDir, removeAll, exists, readDir, readFile } from "std/fs";

const root = cwd();
const mscEnv = env.get("MSC");
const msc = mscEnv != "" ? mscEnv : `${root}/msc`;
const dir = `${root}/out/guardActorArcCountedBeforeSend`;
const WRAPPERS = ["Sink_absorb__", "Sink_weigh__", "Sink_mix__"];

let failed = 0;

function report(msg: string): void {
	console.log(`GUARD-FAIL ${msg}`);
	failed = failed + 1;
}

const source = "struct Payload { n: int32; }\n"
	+ "actor Sink {\n"
	+ "\ttotal: int32 = 0;\n"
	+ "\tabsorb(p: Arc<Payload>): void { this.total = this.total + p.n; }\n"
	+ "\tweigh(p: Arc<Payload>): int32 { return p.n; }\n"
	+ "\tmix(k: int32, p: Arc<Payload>): int32 { return k + p.n; }\n"
	+ "}\n"
	+ "async function main(): Promise<void> {\n"
	+ "\tconst sink = new Sink();\n"
	+ "\tconst a: Arc<Payload> = new Arc({ n: 7 });\n"
	+ "\tsink.absorb(a);\n"
	+ "\tconst w = await sink.weigh(a);\n"
	+ "\tconst m = await sink.mix(1, a);\n"
	+ "\tconsole.log(`${w + m}`);\n"
	+ "}\n"
	+ "main();\n";

function emitted(): string {
	removeAll(dir);
	ensureDir(dir);
	writeFile(`${dir}/main.ms`, source);
	const built = execFileResult(msc, ["build", "main.ms", "--emit=c", "--output=main.c"], dir);
	if (built.exitCode != 0) {
		report(`--emit=c failed: ${built.output}${built.errorOutput}`);
		return "";
	}
	const where = `${dir}/out/debug`;
	if (!exists(where)) {
		report(`no ${where}`);
		return "";
	}
	for (const entry of readDir(where)) {
		if (entry.endsWith("mainOms.c")) {
			const r = readFile(`${where}/${entry}`);
			return r.ok ? r.value : "";
		}
	}
	report("no C file for main.ms in the emitted C");
	return "";
}

function routineBody(text: string, prefix: string): string {
	let at = text.indexOf("\nMS_LIB_PRIVATE ", 0);
	while (at >= 0) {
		const eol = text.indexOf("\n", at + 1);
		const line = text.slice(at + 1, eol < 0 ? text.length : eol);
		if (line.contains(` ${prefix}`) && line.endsWith(" {")) {
			const end = text.indexOf("\n}\n", eol);
			return text.slice(at + 1, end < 0 ? text.length : end);
		}
		at = text.indexOf("\nMS_LIB_PRIVATE ", at + 1);
	}
	return "";
}

const text = emitted();
if (text != "") {
	for (const prefix of WRAPPERS) {
		const body = routineBody(text, prefix);
		if (body == "") {
			report(`sending wrapper ${prefix}* not found in the emitted C`);
			continue;
		}
		const counted = body.indexOf("msMsgSetPtrShared(");
		const send = body.indexOf("msActorSendOrDrop(");
		if (send < 0) report(`${prefix}*: no msActorSendOrDrop`);
		else if (counted < 0) report(`${prefix}*: the Arc goes into the message without a counting setter`);
		else if (counted > send) report(`${prefix}*: the counting setter runs after msActorSendOrDrop`);
	}
}

if (failed != 0) exit(1);
console.log("GUARD-OK");
