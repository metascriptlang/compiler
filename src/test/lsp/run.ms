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
// A scenario with checkpoints is also differential. After each checkpoint drain the runner asks
// the warm session hover and definition at every probe, plus documentSymbol and semantic tokens
// per open document, and compares those answers and the latest publishDiagnostics per document
// with a fresh `<msc> lsp` that opens the same texts at the same URIs. It then writes the texts
// to a directory outside any project and compares each document's compiler diagnostics
// (source "metascript", error or warning) with `<msc> check --colors=off`: start line and byte
// column, severity and message, in order. Batch output has no end column, so ends are pinned by
// the scenario oracles only. Every child runs in that neutral directory, because a file outside
// a project takes its build.ms from the working directory. A scenario with a project is written
// under the neutral directory first, its documents live there, and batch checks them in place.
//
// Env: MSC=<path to msc> (default: ./msc, else installed msc)
//      LSP_REPLAY_TIMEOUT_MS=<deadline of each wait> (default 10000)
import { spawn as spawnChild, ChildProcess, ChildStream, ReadChunk, ProcessError, env, cwd } from "std/process";
import { writeFile, exists, ensureDir, realpath } from "std/fs";
import { basename } from "std/fs/path";
import { stringify } from "std/serialize/json/stringify";
import { parseJson } from "std/serialize/json/parser";
import { JsonKind, JsonValue } from "std/serialize/json/types";
import { getDynamicField, asInt32 } from "std/serialize/json/accessors";
import { lspParseContentLength, lspJsonString } from "../../compiler/lsp/protocol";
import {
	LspScenario,
	LspReplay,
	LspCheckpoints,
	lspScenarios,
	lspTranscript,
	idKey,
	hasKey,
	frames,
	request,
	notification,
	initializeDrain,
	openParams,
	positionParams,
	materialiseProject,
	replaceInFrames,
	projectUri,
	scenarioSlug,
	PROJECT_URI,
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

function neutralDir(): string {
	const unix = env.get("TMPDIR");
	const tmp = unix != "" ? unix : env.get("TEMP");
	const base = slashes(tmp == "" ? "/tmp" : tmp);
	return `${base.endsWith("/") ? base.byteSlice(0, base.byteLength - 1) : base}/mscLspReplay`;
}

const NEUTRAL = neutralDir();

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

function startSession(log: string): Result<Session, string> {
	const started = spawnChild(MSC, ["lsp"], { cwd: NEUTRAL });
	if (!started.ok) return Result.err(`cannot start ${MSC} lsp: ${started.error.message}`);
	return Result.ok({
		child: started.value,
		received: "",
		parsedTo: 0,
		messages: [],
		badFrame: "",
		ended: false,
		log,
	});
}

// ===== The documents a session holds =====

class Snapshot {
	uris: string[];
	texts: string[];
}

function setText(snap: Snapshot, uri: string, text: string): void {
	const at = snap.uris.indexOf(uri);
	if (at >= 0) {
		snap.texts[at] = text;
		return;
	}
	snap.uris.push(uri);
	snap.texts.push(text);
}

// Applies the document edits of one drain; full-text sync is the only kind the server offers.
function applyDrain(snap: Snapshot, drain: string[]): string {
	const bodies: string[] = [];
	for (const frame of drain) completeFrames(frame, 0, bodies);
	for (const body of bodies) {
		const parsed = parseJson(body);
		if (!parsed.ok) continue;
		const m = parsed.value;
		const method = textField(m, "method");
		const uri = textField(m, "params.textDocument.uri");
		if (method == "textDocument/didOpen") setText(snap, uri, textField(m, "params.textDocument.text"));
		if (method == "textDocument/didClose") {
			const at = snap.uris.indexOf(uri);
			if (at >= 0) {
				snap.uris.splice(at, 1);
				snap.texts.splice(at, 1);
			}
		}
		if (method != "textDocument/didChange") continue;
		const changes = m.getDynamicField("params").getDynamicField("contentChanges");
		if (changes.kind != JsonKind.Array) return `didChange of ${uri} has no contentChanges array`;
		for (const change of changes.items) {
			if (hasKey(change, "range")) return `didChange of ${uri} is incremental; a checkpoint needs full text`;
			setText(snap, uri, textField(change, "text"));
		}
	}
	return "";
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
// After each checkpoint drain it runs the differential and stops at the first difference.
function drive(
	s: Session,
	drains: string[][],
	name: string = "",
	checkpoints: LspCheckpoints | null = null,
	inProject: boolean = false,
): Result<int32, string> {
	let shutdownSent = false;
	const snap: Snapshot = { uris: [], texts: [] };
	let taken = 0;
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
		const edited = applyDrain(snap, drains[i]);
		if (edited != "") return Result.err(`drain ${i + 1}: ${edited}`);
		if (checkpoints == null || checkpoints.afterDrains.indexOf(i as int32) < 0) continue;
		taken++;
		const where = `checkpoint ${taken} (after drain ${i + 1})`;
		const differs = compareCheckpoint(s, snap, checkpoints, `${scenarioSlug(name)}-${taken}`, taken, inProject);
		if (differs != "") return Result.err(`${where}: ${differs}`);
	}
	if (checkpoints != null && taken != checkpoints.afterDrains.length) {
		return Result.err(`ran ${taken} of ${checkpoints.afterDrains.length} checkpoints`);
	}
	return Result.ok(drains.length as int32);
}

// ===== Checkpoint differential =====

const QUERY_PREFIX = "cp";

function queryDrain(snap: Snapshot, checkpoints: LspCheckpoints, taken: int32): string[] {
	const bodies: string[] = [];
	let n = 0;
	const next = (): string => {
		n++;
		return lspJsonString(`${QUERY_PREFIX}${taken}-${n}`);
	};
	for (const p of checkpoints.probes) {
		bodies.push(request(next(), "textDocument/hover", positionParams(p.uri, p.line, p.character)));
		bodies.push(request(next(), "textDocument/definition", positionParams(p.uri, p.line, p.character)));
	}
	for (const uri of snap.uris) {
		const document = `{"textDocument":{"uri":${lspJsonString(uri)}}}`;
		bodies.push(request(next(), "textDocument/documentSymbol", document));
		bodies.push(request(next(), "textDocument/semanticTokens/full", document));
	}
	return frames(bodies);
}

function isQueryAnswer(m: JsonValue): boolean {
	if (!hasKey(m, "id") || hasKey(m, "method")) return false;
	return idKey(m.getDynamicField("id")).startsWith(`s:${QUERY_PREFIX}`);
}

// Each query answer as "id => message", in id order of the drain.
function queryAnswers(s: Session, drain: string[]): string[] {
	const bodies: string[] = [];
	for (const frame of drain) completeFrames(frame, 0, bodies);
	const out: string[] = [];
	for (const body of bodies) {
		const parsed = parseJson(body);
		if (!parsed.ok) continue;
		const key = idKey(parsed.value.getDynamicField("id"));
		const method = textField(parsed.value, "method");
		let answer = "no answer";
		for (const m of s.messages) {
			if (isQueryAnswer(m) && idKey(m.getDynamicField("id")) == key) answer = stringify(m);
		}
		out.push(`${method} ${key} => ${answer}`);
	}
	return out;
}

function lastPublish(s: Session, uri: string): JsonValue | null {
	let last: JsonValue | null = null;
	for (const m of s.messages) {
		if (textField(m, "method") == "textDocument/publishDiagnostics" && textField(m, "params.uri") == uri) {
			last = m.getDynamicField("params").getDynamicField("diagnostics");
		}
	}
	return last;
}

function publishText(s: Session, uri: string): string {
	const last = lastPublish(s, uri);
	return last == null ? "no publish" : stringify(last);
}

function freshAnswers(snap: Snapshot, query: string[], name: string): Result<string[], string> {
	const started = startSession(`fresh session for ${name}\n`);
	if (!started.ok) return Result.err(started.error);
	const fresh = started.value;
	const drains: string[][] = [initializeDrain()];
	for (let i = 0; i < snap.uris.length; i++) {
		drains.push(frames([notification("textDocument/didOpen", openParams(snap.uris[i], snap.texts[i]))]));
	}
	drains.push(query);
	const driven = drive(fresh, drains);
	let failure = driven.ok ? "" : driven.error;
	if (failure == "") {
		fresh.child.closeStdin();
		const drained = readToEnd(fresh);
		if (!drained.ok) failure = drained.error;
	}
	fresh.child.close();
	fresh.log += `<<< stderr\n${fresh.child.takeStderr()}\n`;
	writeFile(`${OUT}/${name}-fresh.txt`, fresh.log);
	if (failure != "") return Result.err(`fresh server: ${failure}`);
	const out: string[] = [];
	for (const uri of snap.uris) out.push(`publish ${uri} => ${publishText(fresh, uri)}`);
	for (const answer of queryAnswers(fresh, query)) out.push(answer);
	return Result.ok(out);
}

function firstDifference(what: string, expected: string[], got: string[]): string {
	for (let i = 0; i < expected.length || i < got.length; i++) {
		const e = i < expected.length ? expected[i] : "nothing";
		const g = i < got.length ? got[i] : "nothing";
		if (e != g) return `${what}: warm ${e}, got ${g}`;
	}
	return "";
}

function lineText(text: string, line: int32): string {
	const lines = text.split("\n");
	if (line < 0 || line >= lines.length) return "";
	const t = lines[line];
	return t.endsWith("\r") ? t.byteSlice(0, t.byteLength - 1) : t;
}

// The 0-based byte offset of a UTF-16 column within one line.
function byteColumn(line: string, character: int32): int32 {
	let units = 0;
	let i = 0;
	while (i < line.byteLength && units < character) {
		const b = line.byteAt(i);
		const size = b < 0x80 ? 1 : b < 0xE0 ? 2 : b < 0xF0 ? 3 : 4;
		units += size == 4 ? 2 : 1;
		i += size;
	}
	return i as int32;
}

// The warm compiler diagnostics as batch prints them: "line:byteColumn severity message", 1-based.
function warmCompilerDiagnostics(s: Session, uri: string, text: string): Result<string[], string> {
	const last = lastPublish(s, uri);
	if (last == null) return Result.err(`no publish for ${uri}`);
	if (last.kind != JsonKind.Array) return Result.err(`diagnostics of ${uri} are not an array`);
	const out: string[] = [];
	for (const d of last.items) {
		if (textField(d, "source") != "metascript") continue;
		const level = d.getDynamicField("severity").asInt32(-1);
		if (level != 1 && level != 2) continue;
		const start = d.getDynamicField("range").getDynamicField("start");
		const line = start.getDynamicField("line").asInt32(-1);
		const character = start.getDynamicField("character").asInt32(-1);
		const column = byteColumn(lineText(text, line), character) + 1;
		out.push(`${line + 1}:${column} ${level == 1 ? "error" : "warning"} ${textField(d, "message")}`);
	}
	return Result.ok(out);
}

// Batch diagnostics located in `file`, read from `msc check --colors=off` output.
function parseBatch(output: string, file: string): string[] {
	const lines = output.split("\n");
	const out: string[] = [];
	for (let i = 0; i + 1 < lines.length; i++) {
		const head = lines[i];
		const level = head.startsWith("error: ") ? "error" : head.startsWith("warning: ") ? "warning" : "";
		const arrow = "  --> ";
		if (level == "" || !lines[i + 1].startsWith(arrow)) continue;
		const where = lines[i + 1].byteSlice(arrow.byteLength, lines[i + 1].byteLength);
		const parts = where.split(":");
		if (parts.length < 2) continue;
		const hasColumn = parts.length >= 3;
		const path = parts.slice(0, parts.length - (hasColumn ? 2 : 1)).join(":");
		if (path != file) continue;
		const position = hasColumn ? `${parts[parts.length - 2]}:${parts[parts.length - 1]}` : `${parts[parts.length - 1]}:0`;
		out.push(`${position} ${level} ${head.byteSlice(level.byteLength + 2, head.byteLength)}`);
	}
	return out;
}

// A started check runs while the fresh server is driven; finishCheck reads it and closes it.
function finishCheck(started: Result<ChildProcess, ProcessError>, file: string, name: string): Result<string, string> {
	if (!started.ok) return Result.err(`cannot start ${MSC} check: ${started.error.message}`);
	const child = started.value;
	child.closeStdin();
	let output = "";
	const deadline = performance.now() + TIMEOUT_MS;
	let failure = "";
	while (failure == "") {
		const left = deadline - performance.now();
		if (left <= 0) {
			failure = `check of ${file} did not finish within ${TIMEOUT_MS} ms`;
			break;
		}
		const got = child.read(ChildStream.Stdout, left as int32);
		if (!got.ok) failure = `check of ${file}: ${got.error.message}`;
		else if (got.value.ended) break;
		else output += got.value.data;
	}
	if (failure == "") {
		const status = child.wait(TIMEOUT_MS);
		if (!status.ok) failure = `check of ${file}: no exit status: ${status.error.message}`;
		else if (status.value.signal != 0) failure = `check of ${file} killed by signal ${status.value.signal}`;
	}
	child.close();
	writeFile(`${OUT}/${name}-check-${basename(file)}.txt`, output);
	return failure == "" ? Result.ok(output) : Result.err(failure);
}

function compareCheckpoint(
	s: Session,
	snap: Snapshot,
	checkpoints: LspCheckpoints,
	name: string,
	taken: int32,
	inProject: boolean,
): string {
	const query = queryDrain(snap, checkpoints, taken);
	const queried = drive(s, [query]);
	if (!queried.ok) return `warm queries: ${queried.error}`;
	const warm: string[] = [];
	for (const uri of snap.uris) warm.push(`publish ${uri} => ${publishText(s, uri)}`);
	for (const answer of queryAnswers(s, query)) warm.push(answer);
	writeFile(`${OUT}/${name}-warm.txt`, warm.join("\n") + "\n");

	const dir = `${NEUTRAL}/${name}`;
	ensureDir(dir);
	const files: string[] = [];
	const checks: Result<ChildProcess, ProcessError>[] = [];
	for (let i = 0; i < snap.uris.length; i++) {
		const file = inProject ? lspUriPath(snap.uris[i]) : `${slashes(realpath(dir))}/${basename(lspUriPath(snap.uris[i]))}`;
		writeFile(file, snap.texts[i]);
		files.push(file);
	}
	for (const file of files) checks.push(spawnChild(MSC, ["check", "--colors=off", file], { cwd: NEUTRAL, mergeStderr: true }));
	const outputs: Result<string, string>[] = [];
	const fresh = freshAnswers(snap, query, name);
	for (let i = 0; i < files.length; i++) outputs.push(finishCheck(checks[i], files[i], name));
	if (!fresh.ok) return fresh.error;
	const fromFresh = firstDifference("fresh server", warm, fresh.value);
	if (fromFresh != "") return fromFresh;

	for (let i = 0; i < snap.uris.length; i++) {
		const expected = warmCompilerDiagnostics(s, snap.uris[i], snap.texts[i]);
		if (!expected.ok) return expected.error;
		const output = outputs[i];
		if (!output.ok) return output.error;
		const fromBatch = firstDifference(`msc check ${basename(files[i])}`, expected.value, parseBatch(output.value, files[i]));
		if (fromBatch != "") return fromBatch;
	}
	return "";
}

function lspUriPath(uri: string): string {
	return uri.startsWith("file://") ? uri.byteSlice(7, uri.byteLength) : uri;
}

function verdict(scenario: LspScenario, r: LspReplay): string {
	if (scenario.batching == "any") return scenario.check(r);
	const invariant = scenario.checkAnyBatching;
	if (invariant == null) return "an exact scenario needs checkAnyBatching to run over a pipe";
	return invariant(r);
}

function replayOnProcess(s: Session, scenario: LspScenario, drains: string[][], projectDir: string): string {
	const driven = drive(s, drains, scenario.name, scenario.checkpoints, projectDir != "");
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
	const output = projectDir == "" ? s.received : replaceInFrames(s.received, projectUri(projectDir), PROJECT_URI);
	const r = lspTranscript(output, status.value.code, driven.value);
	r.messages = r.messages.filter((m: JsonValue) => !isQueryAnswer(m));
	return verdict(scenario, r);
}

function runScenario(scenario: LspScenario): string {
	let drains = scenario.drains;
	let projectDir = "";
	const project = scenario.project;
	if (project != null) {
		ensureDir(`${NEUTRAL}/${scenarioSlug(scenario.name)}`);
		projectDir = realpath(`${NEUTRAL}/${scenarioSlug(scenario.name)}`);
		const moved = materialiseProject(project, drains, projectDir);
		if (!moved.ok) return moved.error;
		drains = moved.value;
	}
	const started = startSession(`scenario: ${scenario.name}\ncompiler: ${MSC}\n`);
	if (!started.ok) return started.error;
	const s = started.value;
	const failure = replayOnProcess(s, scenario, drains, projectDir);
	s.child.close();
	s.log += `<<< stderr\n${s.child.takeStderr()}\n`;
	s.log += `=== ${failure == "" ? "ok" : "FAIL " + failure}\n`;
	writeFile(`${OUT}/${scenarioSlug(scenario.name)}.txt`, s.log);
	return failure;
}

function main(): int32 {
	ensureDir(OUT);
	ensureDir(NEUTRAL);
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
