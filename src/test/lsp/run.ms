// LSP replay runner: msc run src/test/lsp/run.ms, from the recompiler root.
//
// Replays the shared scenarios of src/compiler/lsp/replayScenarios.ms against a real
// `<msc> lsp` process. Each drain is one write. Before the next drain the runner waits until
// every request in the drain is answered and, while no shutdown has been sent, until each
// document the drain opens or changes has one more publishDiagnostics; a drain that sends
// `exit` waits for stdout EOF and ends the input. After the last drain stdin is closed and
// stdout is read to EOF. drainsConsumed is the number of drains written in full before the
// server's exit was observed. A pipe may split a drain, so an "exact" scenario is scored by its
// checkAnyBatching. Every wait has a deadline; a miss kills the child and names what was missing.
//
// Env: MSC=<path to msc> (default: ./msc, else installed msc)
//      LSP_REPLAY_TIMEOUT_MS=<deadline of each wait> (default 10000)
import { spawn as spawnChild, ChildProcess, ChildStream, ReadChunk, env, cwd } from "std/process";
import { writeFile, exists, ensureDir } from "std/fs";
import { parseJson } from "std/serialize/json/parser";
import { JsonKind, JsonValue } from "std/serialize/json/types";
import { getDynamicField } from "std/serialize/json/accessors";
import { lspParseContentLength } from "../../compiler/lsp/protocol";
import {
	LspScenario,
	LspReplay,
	lspScenarios,
	lspTranscript,
	idKey,
	hasKey,
} from "../../compiler/lsp/replayScenarios";

function slashes(p: string): string {
	return p.replaceAll("\\", "/");
}

const ROOT = slashes(cwd());

function absolutize(p: string): string {
	const s = slashes(p);
	if (s.startsWith("/") || s.indexOf(":") >= 0) return s;
	return `${ROOT}/${s}`;
}

function resolveMsc(): string {
	const explicit = env.get("MSC");
	if (explicit == "") return exists("./msc") || exists("./msc.exe") ? absolutize("./msc") : "msc";
	const isPath = explicit.indexOf("/") >= 0 || explicit.indexOf("\\") >= 0;
	return isPath ? absolutize(explicit) : explicit;
}

function timeoutMs(): int32 {
	const raw = env.get("LSP_REPLAY_TIMEOUT_MS");
	return raw == "" ? 10000 : raw.parseInt() as int32;
}

const MSC = resolveMsc();
const TIMEOUT_MS = timeoutMs();
const OUT = `${ROOT}/out/lspReplay`;

// ===== Frames =====

// Pushes every complete frame body from `from` on; returns where the incomplete rest begins.
function completeFrames(bytes: string, from: int32, bodies: string[]): int32 {
	let pos = from;
	while (pos < bytes.byteLength) {
		const headerEnd = bytes.byteIndexOf("\r\n\r\n", pos);
		if (headerEnd < 0) return pos;
		const size = lspParseContentLength(bytes.byteSlice(pos, headerEnd));
		const bodyStart = headerEnd + 4;
		if (size < 0 || bodyStart + size > bytes.byteLength) return pos;
		bodies.push(bytes.byteSlice(bodyStart, bodyStart + size));
		pos = bodyStart + size;
	}
	return pos;
}

function textField(m: JsonValue, path: string): string {
	let v = m;
	for (const key of path.split(".")) {
		if (!hasKey(v, key)) return "";
		v = v.getDynamicField(key);
	}
	return v.kind == JsonKind.String ? v.strVal : "";
}

// ===== What a drain waits for =====

interface DrainPlan {
	answers: string[];
	documents: string[];
	exits: boolean;
	shutdownSent: boolean;
}

function planDrain(drain: string[], shutdownBefore: boolean): DrainPlan {
	const plan: DrainPlan = {
		answers: [],
		documents: [],
		exits: false,
		shutdownSent: shutdownBefore,
	};
	const bodies: string[] = [];
	for (const frame of drain) completeFrames(frame, 0, bodies);
	for (const body of bodies) {
		const parsed = parseJson(body);
		if (!parsed.ok) continue;
		const m = parsed.value;
		const method = textField(m, "method");
		if (method == "exit") {
			plan.exits = true;
			return plan;
		}
		const key = hasKey(m, "id") ? idKey(m.getDynamicField("id")) : "";
		if (key != "") plan.answers.push(key);
		if (method == "shutdown") plan.shutdownSent = true;
		const edits = method == "textDocument/didOpen" || method == "textDocument/didChange";
		const uri = textField(m, "params.textDocument.uri");
		const fresh = plan.documents.indexOf(uri) < 0;
		if (edits && !plan.shutdownSent && fresh) plan.documents.push(uri);
	}
	return plan;
}

// ===== One server process =====

class Session {
	child: ChildProcess;
	received: string;
	parsedTo: int32;
	messages: JsonValue[];
	badFrame: string;
	ended: boolean;
	log: string;
}

function absorb(s: Session, chunk: ReadChunk): void {
	if (chunk.ended) {
		s.ended = true;
		s.log += "<<< stdout EOF\n";
		return;
	}
	s.log += `<<< stdout ${chunk.data.byteLength} bytes\n${chunk.data}\n`;
	s.received += chunk.data;
	const bodies: string[] = [];
	s.parsedTo = completeFrames(s.received, s.parsedTo, bodies);
	for (const body of bodies) {
		const parsed = parseJson(body);
		if (parsed.ok) s.messages.push(parsed.value);
		else if (s.badFrame == "") s.badFrame = body;
	}
}

function answerCount(s: Session, key: string): int32 {
	let n = 0;
	for (const m of s.messages) {
		if (hasKey(m, "id") && idKey(m.getDynamicField("id")) == key) {
			n++;
		}
	}
	return n;
}

function publishCount(s: Session, uri: string): int32 {
	let n = 0;
	for (const m of s.messages) {
		const publish = textField(m, "method") == "textDocument/publishDiagnostics";
		if (publish && textField(m, "params.uri") == uri) n++;
	}
	return n;
}

function publishCounts(s: Session, uris: string[]): int32[] {
	const counts: int32[] = [];
	for (const uri of uris) counts.push(publishCount(s, uri));
	return counts;
}

// The first thing the plan still waits for, or "" when it has all arrived.
function missing(s: Session, plan: DrainPlan, publishedBefore: int32[]): string {
	if (plan.exits) return s.ended ? "" : "stdout EOF after exit";
	for (const key of plan.answers) {
		if (answerCount(s, key) == 0) return `answer to ${key}`;
	}
	for (let i = 0; i < plan.documents.length; i++) {
		if (publishCount(s, plan.documents[i]) <= publishedBefore[i]) {
			return `publishDiagnostics for ${plan.documents[i]}`;
		}
	}
	return "";
}

function awaitPlan(s: Session, plan: DrainPlan, publishedBefore: int32[]): Result<void, string> {
	const deadline = performance.now() + TIMEOUT_MS;
	let want = missing(s, plan, publishedBefore);
	while (want != "") {
		if (s.ended) return Result.err(`stdout ended with no ${want}`);
		const left = deadline - performance.now();
		if (left <= 0) return Result.err(`no ${want} within ${TIMEOUT_MS} ms`);
		const got = s.child.read(ChildStream.Stdout, left as int32);
		if (!got.ok) return Result.err(`no ${want} within ${TIMEOUT_MS} ms: ${got.error.message}`);
		absorb(s, got.value);
		want = missing(s, plan, publishedBefore);
	}
	return Result.ok(null);
}

function readToEnd(s: Session): Result<void, string> {
	const deadline = performance.now() + TIMEOUT_MS;
	while (!s.ended) {
		const left = deadline - performance.now();
		const late = `stdout did not end within ${TIMEOUT_MS} ms of closing stdin`;
		if (left <= 0) return Result.err(late);
		const got = s.child.read(ChildStream.Stdout, left as int32);
		if (!got.ok) return Result.err(`${late}: ${got.error.message}`);
		absorb(s, got.value);
	}
	return Result.ok(null);
}

// Writes the drains and waits as the header says; returns the drains written in full.
function drive(s: Session, drains: string[][]): Result<int32, string> {
	let shutdownSent = false;
	for (let i = 0; i < drains.length; i++) {
		const plan = planDrain(drains[i], shutdownSent);
		shutdownSent = plan.shutdownSent;
		const before = publishCounts(s, plan.documents);
		const bytes = drains[i].join("");
		s.log += `>>> drain ${i + 1} (${bytes.byteLength} bytes)\n${bytes}\n`;
		const sent = s.child.write(bytes, TIMEOUT_MS);
		if (!sent.ok) {
			s.log += `>>> write failed: ${sent.error.message}\n`;
			return Result.ok(i as int32);
		}
		const waited = awaitPlan(s, plan, before);
		if (!waited.ok) return Result.err(`drain ${i + 1}: ${waited.error}`);
		if (plan.exits) return Result.ok((i + 1) as int32);
	}
	return Result.ok(drains.length as int32);
}

function verdict(scenario: LspScenario, r: LspReplay): string {
	if (scenario.batching == "any") return scenario.check(r);
	const invariant = scenario.checkAnyBatching;
	if (invariant == null) return "an exact scenario needs checkAnyBatching to run over a pipe";
	return invariant(r);
}

function replayOnProcess(s: Session, scenario: LspScenario): string {
	const driven = drive(s, scenario.drains);
	if (!driven.ok) return driven.error;
	s.child.closeStdin();
	const drained = readToEnd(s);
	if (!drained.ok) return drained.error;
	const status = s.child.wait(TIMEOUT_MS);
	if (!status.ok) return `no exit status: ${status.error.message}`;
	s.log += `=== exit code=${status.value.code} signal=${status.value.signal}\n`;
	if (status.value.signal != 0) return `server killed by signal ${status.value.signal}`;
	if (s.badFrame != "") return `server frame is not JSON: ${s.badFrame}`;
	if (s.parsedTo != s.received.byteLength) {
		return `stdout ends inside a frame at byte ${s.parsedTo} of ${s.received.byteLength}`;
	}
	return verdict(scenario, lspTranscript(s.received, status.value.code, driven.value));
}

function slug(name: string): string {
	let out = "";
	for (let i = 0; i < name.byteLength; i++) {
		const b = name.byteAt(i);
		const keep = (b >= 97 && b <= 122) || (b >= 65 && b <= 90) || (b >= 48 && b <= 57);
		if (keep) out += name.byteSlice(i, i + 1);
		else if (!out.endsWith("-")) out += "-";
	}
	return out;
}

function runScenario(scenario: LspScenario): string {
	const started = spawnChild(MSC, ["lsp"]);
	if (!started.ok) return `cannot start ${MSC} lsp: ${started.error.message}`;
	const s: Session = {
		child: started.value,
		received: "",
		parsedTo: 0,
		messages: [],
		badFrame: "",
		ended: false,
		log: `scenario: ${scenario.name}\ncompiler: ${MSC}\n`,
	};
	const failure = replayOnProcess(s, scenario);
	s.child.close();
	s.log += `<<< stderr\n${s.child.takeStderr()}\n`;
	s.log += `=== ${failure == "" ? "ok" : "FAIL " + failure}\n`;
	writeFile(`${OUT}/${slug(scenario.name)}.txt`, s.log);
	return failure;
}

function main(): int32 {
	ensureDir(OUT);
	console.log(`lsp-replay: compiler under test = ${MSC}`);
	let passes = 0;
	let fails = 0;
	for (const scenario of lspScenarios()) {
		const failure = runScenario(scenario);
		if (failure == "") {
			passes++;
			console.log(`ok   ${scenario.name}`);
		} else {
			fails++;
			console.log(`FAIL ${scenario.name}: ${failure}`);
		}
	}
	console.log(fails == 0
		? `lsp-replay: ALL GREEN (${passes} scenarios)`
		: `lsp-replay: FAILURES ABOVE (${passes} ok, ${fails} red)`);
	return fails > 0 ? 1 : 0;
}

process.exit(main());
