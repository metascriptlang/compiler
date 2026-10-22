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
// LSP_PERF=1 times the same scenarios instead, plus a 3-module chain and a pinned real app,
// over repetitions in alternating order, and prints one JSON line per cell (metric x fixture).
// A drain is timed from its write: startup from spawn to the initialize answer, an open or
// edit from a drain holding only that document's notifications to its next publish, hover and
// completion from a drain holding only that request, sent at every checkpoint probe after the
// checkpoint agreed. Queue delay and the server's own split come from its stderr, read after
// every drain until its [LSP-STATS] line. A fixture whose scenario fails in any repetition
// reports every cell as an error.
//
// Env: MSC=<path to msc> (default: ./msc, else installed msc)
//      LSP_REPLAY_TIMEOUT_MS=<deadline of each wait> (default 10000)
//      LSP_PERF=1, LSP_PERF_REPS=<repetitions> (default 5), LSP_PERF_OUT=<file> (default stdout)
import {
	spawn as spawnChild,
	ChildProcess,
	ChildStream,
	ReadChunk,
	ProcessError,
	ProcessErrorKind,
	env,
	cwd,
	execFileCapture,
	findOnPath,
} from "std/process";
import { writeFile, readFile, exists, ensureDir, realpath } from "std/fs";
import { basename, dirname } from "std/fs/path";
import { stringify } from "std/serialize/json/stringify";
import { parseJson } from "std/serialize/json/parser";
import { JsonKind, JsonValue } from "std/serialize/json/types";
import { getDynamicField, asInt32 } from "std/serialize/json/accessors";
import { lspParseContentLength, lspJsonString } from "../../compiler/lsp/protocol";
import {
	LspScenario,
	LspReplay,
	LspCheckpoints,
	LspProbe,
	lspScenarios,
	lspTranscript,
	idKey,
	hasKey,
	frames,
	request,
	notification,
	initializeDrain,
	openParams,
	changeParams,
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
const PERF = env.get("LSP_PERF") == "1";
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
	arrivals: number[];
	badFrame: string;
	ended: boolean;
	timedOut: boolean;
	log: string;
	measured: boolean;
	startedAt: number;
	drainsWritten: int32;
	opened: string[];
	stderrText: string;
	samples: PerfSample[];
	usage: ProcessUsage[];
	rssBeforeEdits: number;
	rssAfterEdits: number;
	editDrains: int32;
}

function startSession(log: string, measured: boolean = false): Result<Session, string> {
	const startedAt = performance.now();
	const started = spawnChild(MSC, ["lsp"], { cwd: NEUTRAL });
	if (!started.ok) return Result.err(`cannot start ${MSC} lsp: ${started.error.message}`);
	return Result.ok({
		child: started.value,
		received: "",
		parsedTo: 0,
		messages: [],
		arrivals: [],
		badFrame: "",
		ended: false,
		timedOut: false,
		log,
		measured,
		startedAt,
		drainsWritten: 0,
		opened: [],
		stderrText: "",
		samples: [],
		usage: [],
		rssBeforeEdits: -1,
		rssAfterEdits: -1,
		editDrains: 0,
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
	const now = performance.now();
	s.log += `<<< stdout ${chunk.data.byteLength} bytes\n${chunk.data}\n`;
	s.received += chunk.data;
	const bodies: string[] = [];
	s.parsedTo = completeFrames(s.received, s.parsedTo, bodies);
	for (const body of bodies) {
		const parsed = parseJson(body);
		if (parsed.ok) {
			s.messages.push(parsed.value);
			s.arrivals.push(now);
		} else if (s.badFrame == "") s.badFrame = body;
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
		if (left <= 0) {
			s.timedOut = true;
			return Result.err(`no ${want} within ${TIMEOUT_MS} ms`);
		}
		const got = s.child.read(ChildStream.Stdout, left as int32);
		if (!got.ok) {
			s.timedOut = got.error.kind == ProcessErrorKind.Timeout;
			return Result.err(`no ${want} within ${TIMEOUT_MS} ms: ${got.error.message}`);
		}
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
		s.drainsWritten++;
		if (s.measured && s.editDrains == 0 && changesText(drains[i])) {
			const usage = readUsage(s);
			if (!usage.ok) return Result.err(`drain ${i + 1}: ${usage.error}`);
			s.rssBeforeEdits = usage.value.rssKb;
		}
		const writtenAt = performance.now();
		const sent = s.child.write(bytes, TIMEOUT_MS);
		if (!sent.ok) {
			s.log += `>>> write failed: ${sent.error.message}\n`;
			return Result.ok(i as int32);
		}
		const waited = awaitPlan(s, plan, before);
		if (!waited.ok) return Result.err(`drain ${i + 1}: ${waited.error}`);
		if (s.measured) {
			const measured = measureDrain(s, plan, drains[i], before, writtenAt);
			if (measured != "") return Result.err(`drain ${i + 1}: ${measured}`);
		}
		if (plan.exits) return Result.ok((i + 1) as int32);
		const edited = applyDrain(snap, drains[i]);
		if (edited != "") return Result.err(`drain ${i + 1}: ${edited}`);
		if (checkpoints == null || checkpoints.afterDrains.indexOf(i as int32) < 0) continue;
		taken++;
		const where = `checkpoint ${taken} (after drain ${i + 1})`;
		const differs = compareCheckpoint(s, snap, checkpoints, `${scenarioSlug(name)}-${taken}`, taken, inProject);
		if (differs != "") return Result.err(`${where}: ${differs}`);
		const probed = s.measured ? timeProbes(s, checkpoints, taken) : "";
		if (probed != "") return Result.err(`${where}: ${probed}`);
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
	fresh.log += `<<< stderr\n${fresh.child.takeStderr()}\n`;
	fresh.child.close();
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

// The probes of a project scenario, moved off PROJECT_URI as its drains are.
function movedCheckpoints(
	checkpoints: LspCheckpoints | null,
	projectDir: string,
): LspCheckpoints | null {
	if (checkpoints == null || projectDir == "") return checkpoints;
	const probes: LspProbe[] = [];
	for (const p of checkpoints.probes) {
		const uri = p.uri.replaceAll(PROJECT_URI, projectUri(projectDir));
		probes.push({ uri, line: p.line, character: p.character });
	}
	return { afterDrains: checkpoints.afterDrains, probes };
}

function replayOnProcess(s: Session, scenario: LspScenario, drains: string[][], projectDir: string): string {
	const checkpoints = movedCheckpoints(scenario.checkpoints, projectDir);
	const driven = drive(s, drains, scenario.name, checkpoints, projectDir != "");
	if (!driven.ok) return driven.error;
	if (s.measured && !s.ended) {
		const sampled = sampleUsage(s);
		if (sampled != "") return sampled;
	}
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

class ScenarioRun {
	failure: string;
	timedOut: boolean;
	samples: PerfSample[];
	usage: ProcessUsage[];
}

function runScenario(scenario: LspScenario): ScenarioRun {
	let drains = scenario.drains;
	let projectDir = "";
	const project = scenario.project;
	if (project != null) {
		ensureDir(`${NEUTRAL}/${scenarioSlug(scenario.name)}`);
		projectDir = slashes(realpath(`${NEUTRAL}/${scenarioSlug(scenario.name)}`));
		const moved = materialiseProject(project, drains, projectDir);
		if (!moved.ok) return { failure: moved.error, timedOut: false, samples: [], usage: [] };
		drains = moved.value;
	}
	const started = startSession(`scenario: ${scenario.name}\ncompiler: ${MSC}\n`, PERF);
	if (!started.ok) return { failure: started.error, timedOut: false, samples: [], usage: [] };
	const s = started.value;
	const failure = replayOnProcess(s, scenario, drains, projectDir);
	s.log += `<<< stderr\n${s.child.takeStderr()}\n`;
	s.child.close();
	s.log += `=== ${failure == "" ? "ok" : "FAIL " + failure}\n`;
	writeFile(`${OUT}/${scenarioSlug(scenario.name)}.txt`, s.log);
	for (const sample of editGrowth(s)) s.samples.push(sample);
	return { failure, timedOut: s.timedOut, samples: s.samples, usage: s.usage };
}

// ===== Perf mode =====

interface PerfSample {
	metric: string;
	value: number;
}

interface ProcessUsage {
	drain: int32;
	rssKb: number;
	cpuMs: number;
}

const USAGE_EVERY = 10;
const PROBE_ROUNDS = 3;
const EDITS = 40;
const COLD_OPENS_PER_REPETITION = 8;
const NEON_REV = "5b2c634a23646ce3796797ec4d79e2d4c2360969";
const VOID_REV = "a29845a0fd75c3fd6c0c8d0d0205882965a31d25";
const YOGA_REV = "f92ae144a943eab59ad9ea375de65f3bf131635f";
const TODO_LIST = "neon/examples/components/todoList.ms";
const METRICS = [
	["startup-to-ready", "ms"],
	["open-to-diagnostics", "ms"],
	["open-server", "ms"],
	["edit-to-diagnostics", "ms"],
	["edit-server", "ms"],
	["hover", "ms"],
	["completion", "ms"],
	["queue-delay", "ms"],
	["rss", "kB"],
	["rss-growth", "kB/drain"],
	["cpu", "ms/drain"],
];

function perfRepetitions(): int32 {
	const raw = env.get("LSP_PERF_REPS");
	return raw == "" ? 5 : raw.parseInt() as int32;
}

function bodiesOf(drain: string[]): JsonValue[] {
	const bodies: string[] = [];
	for (const frame of drain) completeFrames(frame, 0, bodies);
	const out: JsonValue[] = [];
	for (const body of bodies) {
		const parsed = parseJson(body);
		if (parsed.ok) out.push(parsed.value);
	}
	return out;
}

function isPublishFor(m: JsonValue, uri: string): boolean {
	const publish = textField(m, "method") == "textDocument/publishDiagnostics";
	return publish && textField(m, "params.uri") == uri;
}

// When the publish for uri that follows the first `before` ones arrived, or -1.
function publishArrival(s: Session, uri: string, before: int32): number {
	let n = 0;
	for (let k = 0; k < s.messages.length; k++) {
		const m = s.messages[k];
		if (!isPublishFor(m, uri)) continue;
		if (n == before) return s.arrivals[k];
		n++;
	}
	return -1;
}

function answerIndex(s: Session, key: string): int32 {
	for (let k = 0; k < s.messages.length; k++) {
		const m = s.messages[k];
		const answer = hasKey(m, "id") && !hasKey(m, "method");
		if (answer && idKey(m.getDynamicField("id")) == key) return k as int32;
	}
	return -1;
}

function answerResult(s: Session, key: string): string {
	const k = answerIndex(s, key);
	if (k < 0) return "no answer";
	const m = s.messages[k];
	if (!hasKey(m, "result")) return `no result: ${stringify(m)}`;
	return stringify(m.getDynamicField("result"));
}

// Moves the complete lines of s.stderrText into lines; says whether one was [LSP-STATS].
function takeLines(s: Session, lines: string[]): boolean {
	const parts = s.stderrText.split("\n");
	s.stderrText = parts[parts.length - 1];
	let stats = false;
	for (let k = 0; k + 1 < parts.length; k++) {
		lines.push(parts[k]);
		if (parts[k].startsWith("[LSP-STATS] ")) stats = true;
	}
	return stats;
}

// The stderr lines of the drain just answered; the server ends each of its drains with an
// [LSP-STATS] line, unless the drain ends the server.
function drainStderr(s: Session, waitForStats: boolean): Result<string[], string> {
	const lines: string[] = [];
	s.stderrText += s.child.takeStderr();
	let stats = takeLines(s, lines);
	const deadline = performance.now() + TIMEOUT_MS;
	while (waitForStats && !stats) {
		const left = deadline - performance.now();
		if (left <= 0) {
			s.timedOut = true;
			return Result.err(`no [LSP-STATS] line within ${TIMEOUT_MS} ms`);
		}
		const got = s.child.read(ChildStream.Stderr, left as int32);
		if (!got.ok) {
			s.timedOut = got.error.kind == ProcessErrorKind.Timeout;
			return Result.err(`no [LSP-STATS] line: ${got.error.message}`);
		}
		if (got.value.ended) return Result.err("stderr ended with no [LSP-STATS] line");
		s.stderrText += got.value.data;
		stats = takeLines(s, lines);
	}
	return Result.ok(lines);
}

// The number after `key` in a server log line, up to its "ms".
function loggedMs(line: string, key: string): Result<number, string> {
	const at = line.byteIndexOf(key, 0);
	if (at < 0) return Result.err(`server line has no ${key}: ${line}`);
	const from = at + key.byteLength;
	const end = line.byteIndexOf("ms", from);
	return Result.ok(line.byteSlice(from, end < 0 ? line.byteLength : end).parseFloat());
}

function sampleLogged(s: Session, metric: string, line: string, key: string): string {
	const ms = loggedMs(line, key);
	if (!ms.ok) return ms.error;
	s.samples.push({ metric, value: ms.value });
	return "";
}

// Ps prints "<rss kB> <[hh:]mm:ss[.cc]>" for the server: its resident size and CPU so far.
function readUsage(s: Session): Result<ProcessUsage, string> {
	const ps = execFileCapture("ps", ["-o", "rss=,time=", "-p", `${s.child.pid}`]);
	if (!ps.ok) return Result.err(`ps of the server: ${ps.error.message}`);
	const fields: string[] = [];
	for (const f of ps.value.trim().split(" ")) {
		if (f != "") fields.push(f);
	}
	if (fields.length != 2) return Result.err(`ps of the server printed ${lspJsonString(ps.value)}`);
	let cpuSeconds: number = 0;
	for (const part of fields[1].split(":")) cpuSeconds = cpuSeconds * 60 + part.parseFloat();
	const rssKb = fields[0].parseFloat();
	return Result.ok({ drain: s.drainsWritten, rssKb, cpuMs: cpuSeconds * 1000 });
}

function sampleUsage(s: Session): string {
	const usage = readUsage(s);
	if (!usage.ok) return usage.error;
	s.usage.push(usage.value);
	return "";
}

function changesText(drain: string[]): boolean {
	for (const m of bodiesOf(drain)) {
		if (textField(m, "method") == "textDocument/didChange") return true;
	}
	return false;
}

// Growth across the warm edits: RSS before the first edit drain to after the last, per edit.
function editGrowth(s: Session): PerfSample[] {
	if (s.editDrains == 0) return [];
	const growth = (s.rssAfterEdits - s.rssBeforeEdits) / s.editDrains;
	return [{ metric: "rss-growth", value: growth }];
}

function measureDrain(
	s: Session,
	plan: DrainPlan,
	drain: string[],
	before: int32[],
	writtenAt: number,
): string {
	const waitForStats = !plan.exits && (plan.answers.length > 0 || plan.documents.length > 0);
	const read = drainStderr(s, waitForStats);
	if (!read.ok) return read.error;
	const lines = read.value;
	s.log += `<<< stderr after drain ${s.drainsWritten}\n${lines.join("\n")}\n`;
	let requests = 0;
	let requestMethod = "";
	let requestKey = "";
	let editMethod = "";
	const opens: string[] = [];
	for (const m of bodiesOf(drain)) {
		const method = textField(m, "method");
		if (hasKey(m, "id")) {
			requests++;
			requestMethod = method;
			requestKey = idKey(m.getDynamicField("id"));
			const k = answerIndex(s, requestKey);
			if (method == "initialize" && s.drainsWritten == 1 && k >= 0) {
				s.samples.push({ metric: "startup-to-ready", value: s.arrivals[k] - s.startedAt });
			}
		}
		const edits = method == "textDocument/didOpen" || method == "textDocument/didChange";
		if (edits && editMethod == "") editMethod = method;
		if (method == "textDocument/didOpen") opens.push(textField(m, "params.textDocument.uri"));
	}
	for (const line of lines) {
		if (!line.startsWith("[LSP-QUEUE] ")) continue;
		const sampled = sampleLogged(s, "queue-delay", line, " delay=");
		if (sampled != "") return sampled;
	}
	if (requests == 0 && plan.documents.length == 1) {
		const uri = plan.documents[0];
		const took = publishArrival(s, uri, before[0]) - writtenAt;
		const cold = editMethod == "textDocument/didOpen" && s.opened.indexOf(uri) < 0;
		const edit = editMethod == "textDocument/didChange";
		if (cold) s.samples.push({ metric: "open-to-diagnostics", value: took });
		if (edit) s.samples.push({ metric: "edit-to-diagnostics", value: took });
		for (const line of lines) {
			const opened = cold && line.startsWith("[LSP-OPEN] ");
			const changed = edit && line.startsWith("[LSP-CHANGE] ");
			if (!opened && !changed) continue;
			const sampled = sampleLogged(s, opened ? "open-server" : "edit-server", line, " total=");
			if (sampled != "") return sampled;
		}
	}
	const hover = requestMethod == "textDocument/hover";
	const probe = hover || requestMethod == "textDocument/completion";
	if (requests == 1 && plan.documents.length == 0 && probe) {
		const k = answerIndex(s, requestKey);
		const metric = hover ? "hover" : "completion";
		if (k >= 0) s.samples.push({ metric, value: s.arrivals[k] - writtenAt });
	}
	for (const uri of opens) {
		if (s.opened.indexOf(uri) < 0) s.opened.push(uri);
	}
	if (changesText(drain) && !s.ended) {
		const usage = readUsage(s);
		if (!usage.ok) return usage.error;
		s.editDrains++;
		s.rssAfterEdits = usage.value.rssKb;
	}
	const due = s.drainsWritten == 1 || s.drainsWritten % USAGE_EVERY == 0;
	return due && !plan.exits && !s.ended ? sampleUsage(s) : "";
}

// Asks hover and completion alone at every probe once the checkpoint agreed: the hover must
// answer what the checkpoint's hover answered, the completion must answer a result.
function timeProbes(s: Session, checkpoints: LspCheckpoints, taken: int32): string {
	for (let round = 0; round < PROBE_ROUNDS; round++) {
		for (let k = 0; k < checkpoints.probes.length; k++) {
			const p = checkpoints.probes[k];
			const at = positionParams(p.uri, p.line, p.character);
			const hoverId = `${QUERY_PREFIX}${taken}-hover-${round}-${k}`;
			const where = `${p.line}:${p.character}`;
			const hover = request(lspJsonString(hoverId), "textDocument/hover", at);
			const hovered = drive(s, [frames([hover])]);
			if (!hovered.ok) return `timed hover: ${hovered.error}`;
			const want = answerResult(s, `s:${QUERY_PREFIX}${taken}-${2 * k + 1}`);
			const got = answerResult(s, `s:${hoverId}`);
			if (got != want) return `timed hover at ${where}: checkpoint ${want}, got ${got}`;
			const completionId = `${QUERY_PREFIX}${taken}-completion-${round}-${k}`;
			const completion = request(lspJsonString(completionId), "textDocument/completion", at);
			const completed = drive(s, [frames([completion])]);
			if (!completed.ok) return `timed completion: ${completed.error}`;
			const answer = answerResult(s, `s:${completionId}`);
			if (answer.startsWith("no ")) return `timed completion at ${where}: ${answer}`;
		}
	}
	return "";
}

function usageSamples(usage: ProcessUsage[]): PerfSample[] {
	const out: PerfSample[] = [];
	for (let k = 0; k < usage.length; k++) {
		out.push({ metric: "rss", value: usage[k].rssKb });
		if (k == 0 || usage[k].drain == usage[k - 1].drain) continue;
		const drains = usage[k].drain - usage[k - 1].drain;
		out.push({ metric: "cpu", value: (usage[k].cpuMs - usage[k - 1].cpuMs) / drains });
	}
	return out;
}

// ===== Perf fixtures =====

interface PerfEntry {
	scenario: LspScenario;
	fixture: string;
}

function openDrain(uri: string, text: string): string[] {
	return frames([notification("textDocument/didOpen", openParams(uri, text))]);
}

function changeDrain(uri: string, version: int32, text: string): string[] {
	return frames([notification("textDocument/didChange", changeParams(uri, version, text))]);
}

// "" when uri was published `publishes` times (at least once when -1) with no error.
function publishedWithoutErrors(r: LspReplay, uri: string, publishes: int32): string {
	let n = 0;
	for (const m of r.messages) {
		if (!isPublishFor(m, uri)) continue;
		n++;
		const diagnostics = m.getDynamicField("params").getDynamicField("diagnostics");
		const which = `publish ${n} of ${uri}`;
		if (diagnostics.kind != JsonKind.Array) return `${which} has no diagnostics array`;
		for (const d of diagnostics.items) {
			if (d.getDynamicField("severity").asInt32(-1) == 1) return `${which}: ${stringify(d)}`;
		}
	}
	if (publishes < 0 ? n > 0 : n == publishes) return "";
	return `${uri} published ${n} times, expected ${publishes < 0 ? "some" : `${publishes}`}`;
}

function projectDirOf(name: string): Result<string, string> {
	const dir = `${NEUTRAL}/${scenarioSlug(name)}`;
	if (!ensureDir(dir).ok) return Result.err(`cannot create ${dir}`);
	return Result.ok(realpath(dir));
}

function chainEditLoop(): LspScenario {
	const logic = PROJECT_URI + "chain/logic.ms";
	const mid = PROJECT_URI + "chain/mid.ms";
	const far = PROJECT_URI + "chain/far.ms";
	const one = "export function value(): int32 { return 1; }\n";
	const two = "export function value(): int32 { return 2; }\n";
	const midText = "import { value } from \"./logic\";\n"
		+ "export function midValue() { return value(); }\n";
	const farText = "import { midValue } from \"./mid\";\n"
		+ "export const farValue = () => midValue();\n";
	const drains = [
		initializeDrain(),
		openDrain(logic, one),
		openDrain(mid, midText),
		openDrain(far, farText),
	];
	for (let k = 0; k < EDITS; k++) {
		drains.push(changeDrain(logic, (k + 2) as int32, k % 2 == 0 ? two : one));
	}
	return {
		name: "perf: a body edit at the root of a 3-module chain",
		batching: "any",
		drains,
		check: (r: LspReplay) => {
			const logicFailure = publishedWithoutErrors(r, logic, (EDITS + 1) as int32);
			if (logicFailure != "") return logicFailure;
			const midFailure = publishedWithoutErrors(r, mid, -1);
			return midFailure != "" ? midFailure : publishedWithoutErrors(r, far, -1);
		},
		checkAnyBatching: null,
		checkpoints: {
			afterDrains: [3, (drains.length - 1) as int32],
			probes: [{ uri: mid, line: 1, character: 36 }, { uri: far, line: 1, character: 30 }],
		},
		project: [
			{ path: "chain/logic.ms", text: one },
			{ path: "chain/mid.ms", text: midText },
			{ path: "chain/far.ms", text: farText },
		],
	};
}

function probeAt(uri: string, text: string, marker: string): Result<LspProbe, string> {
	const lines = text.split("\n");
	for (let line = 0; line < lines.length; line++) {
		const at = lines[line].byteIndexOf(marker, 0);
		if (at >= 0) return Result.ok({ uri, line: line as int32, character: at as int32 });
	}
	return Result.err(`no ${marker} in ${TODO_LIST}`);
}

function todoListEditLoop(name: string, text: string): Result<LspScenario, string> {
	const uri = PROJECT_URI + TODO_LIST;
	const edited = text.replaceAll("\"ship the starter\"", "\"ship the starter now\"");
	if (edited == text) return Result.err(`${TODO_LIST} has no "ship the starter" to edit`);
	const signal = try probeAt(uri, text, "createSignal<Todo[]>");
	const setter = try probeAt(uri, text, "setTodos(next);");
	const drains = [initializeDrain(), openDrain(uri, text)];
	for (let k = 0; k < EDITS; k++) {
		drains.push(changeDrain(uri, (k + 2) as int32, k % 2 == 0 ? edited : text));
	}
	return Result.ok({
		name,
		batching: "any",
		drains,
		check: (r: LspReplay) => publishedWithoutErrors(r, uri, (EDITS + 1) as int32),
		checkAnyBatching: null,
		checkpoints: { afterDrains: [1, (drains.length - 1) as int32], probes: [signal, setter] },
		project: [],
	});
}

function todoListColdOpen(name: string, text: string): LspScenario {
	const uri = PROJECT_URI + TODO_LIST;
	return {
		name,
		batching: "any",
		drains: [initializeDrain(), openDrain(uri, text)],
		check: (r: LspReplay) => publishedWithoutErrors(r, uri, 1),
		checkAnyBatching: null,
		checkpoints: null,
		project: [],
	};
}

function commandOutput(path: string, args: string[], dir: string = ""): Result<string, string> {
	const ran = execFileCapture(path, args, dir);
	if (!ran.ok) return Result.err(`${path} ${args.join(" ")}: ${ran.error.message}`);
	return Result.ok(ran.value.trim());
}

// The recompiler's main checkout sits in the workspace beside neon, void and yoga.
function workspaceDir(): Result<string, string> {
	const args = ["rev-parse", "--path-format=absolute", "--git-common-dir"];
	const common = try commandOutput("git", args, ROOT);
	return Result.ok(dirname(dirname(common)));
}

// Writes the real app at its pinned commits under dir, laid out as neon imports it. The
// shader headers stay out: over 100 MB, and no module the app reaches imports them.
function extractTodoList(dir: string): Result<void, string> {
	const workspace = try workspaceDir();
	const repos = [
		["neon", NEON_REV, "build.ms", "src", "examples/components"],
		["void", VOID_REV, "build.ms", "src", ":(exclude)*.glsl.h"],
		["yoga", YOGA_REV, "build.ms", "src"],
	];
	for (const repo of repos) {
		const tar = `${NEUTRAL}/${repo[0]}-${repo[1]}.tar`;
		const args = ["-C", `${workspace}/${repo[0]}`, "archive", `--prefix=${repo[0]}/`];
		for (const arg of ["-o", tar, repo[1], "--"]) args.push(arg);
		for (let k = 2; k < repo.length; k++) args.push(repo[k]);
		try commandOutput("git", args);
		try commandOutput("tar", ["-xf", tar, "-C", dir]);
	}
	return Result.ok(null);
}

function recompilerRevision(): Result<string, string> {
	const head = try commandOutput("git", ["rev-parse", "--short=12", "HEAD"], ROOT);
	const status = ["status", "--porcelain", "--", "src/test/lsp", "src/compiler/lsp"];
	const dirty = try commandOutput("git", status, ROOT);
	return Result.ok(`recompiler@${head}${dirty == "" ? "" : "+dirty"}`);
}

function perfEntries(): Result<PerfEntry[], string> {
	const editName = `perf: todoList at neon ${NEON_REV.byteSlice(0, 8)}, an edit loop`;
	const openName = `perf: todoList at neon ${NEON_REV.byteSlice(0, 8)}, a cold open`;
	const editDir = try projectDirOf(editName);
	const openDir = try projectDirOf(openName);
	try extractTodoList(editDir);
	try extractTodoList(openDir);
	const read = readFile(`${editDir}/${TODO_LIST}`);
	if (!read.ok) return Result.err(`cannot read ${TODO_LIST} under ${editDir}`);
	const editLoop: PerfEntry = {
		scenario: try todoListEditLoop(editName, read.value),
		fixture: "todoList",
	};
	const coldOpen: PerfEntry = {
		scenario: todoListColdOpen(openName, read.value),
		fixture: "todoList",
	};
	const small: PerfEntry[] = [{ scenario: chainEditLoop(), fixture: "small" }];
	for (const scenario of lspScenarios()) small.push({ scenario, fixture: "small" });
	const entries: PerfEntry[] = [];
	let opens = 0;
	for (let k = 0; k < small.length; k++) {
		entries.push(small[k]);
		if (k == small.length / 2) entries.push(editLoop);
		if (k % 3 == 1 && opens < COLD_OPENS_PER_REPETITION) {
			entries.push(coldOpen);
			opens++;
		}
	}
	while (opens < COLD_OPENS_PER_REPETITION) {
		entries.push(coldOpen);
		opens++;
	}
	return Result.ok(entries);
}

// ===== Perf cells =====

class PerfCell {
	metric: string;
	unit: string;
	fixture: string;
	revision: string;
	values: number[];
	repetitions: int32[];
	timeouts: int32;
	errors: int32;
	error: string;
}

function record(cells: PerfCell[], entry: PerfEntry, run: ScenarioRun, repetition: int32): void {
	const samples = run.samples;
	for (const sample of usageSamples(run.usage)) samples.push(sample);
	for (const cell of cells) {
		if (cell.fixture != entry.fixture) continue;
		if (run.failure != "") {
			cell.errors++;
			if (run.timedOut) cell.timeouts++;
			if (cell.error == "") cell.error = `${entry.scenario.name}: ${run.failure}`;
			continue;
		}
		for (const sample of samples) {
			if (sample.metric != cell.metric) continue;
			cell.values.push(sample.value);
			if (cell.repetitions.indexOf(repetition) < 0) cell.repetitions.push(repetition);
		}
	}
}

function nearestRank(sorted: number[], percent: int32): number {
	const rank = ((sorted.length as int32) * percent + 99) / 100;
	return sorted[rank < 1 ? 0 : rank - 1];
}

function cellLine(cell: PerfCell, uptimeStart: string, uptimeEnd: string, binary: string): string {
	const n = cell.values.length;
	let line = `{"cell":${lspJsonString(cell.metric)},"fixture":${lspJsonString(cell.fixture)}`
		+ `,"unit":${lspJsonString(cell.unit)},"n":${n},"repetitions":${cell.repetitions.length}`;
	const error = cell.error != "" ? cell.error : n == 0 ? "no samples" : "";
	if (error != "") line += `,"error":${lspJsonString(error)}`;
	else {
		const sorted: number[] = [];
		for (const v of cell.values) sorted.push(v);
		sorted.sort();
		line += `,"min":${sorted[0]},"p50":${nearestRank(sorted, 50)}`
			+ `,"p95":${nearestRank(sorted, 95)}`;
	}
	return line + `,"timeouts":${cell.timeouts},"errors":${cell.errors}`
		+ `,"uptimeStart":${lspJsonString(uptimeStart)},"uptimeEnd":${lspJsonString(uptimeEnd)}`
		+ `,"binary":${lspJsonString(binary)},"revision":${lspJsonString(cell.revision)}}`;
}

function perfRun(): Result<boolean, string> {
	ensureDir(OUT);
	ensureDir(NEUTRAL);
	const uptimeStart = try commandOutput("uptime", []);
	const msc = findOnPath(MSC);
	if (msc == "") return Result.err(`${MSC} is not on PATH`);
	const hashed = try commandOutput("shasum", ["-a", "256", msc]);
	const binary = `sha256:${hashed.split(" ")[0]}`;
	const small = try recompilerRevision();
	const app = `neon@${NEON_REV.byteSlice(0, 12)} void@${VOID_REV.byteSlice(0, 12)}`
		+ ` yoga@${YOGA_REV.byteSlice(0, 12)}`;
	const entries = try perfEntries();
	const cells: PerfCell[] = [];
	for (const fixture of ["small", "todoList"]) {
		for (const metric of METRICS) {
			cells.push({
				metric: metric[0],
				unit: metric[1],
				fixture,
				revision: fixture == "small" ? small : app,
				values: [],
				repetitions: [],
				timeouts: 0,
				errors: 0,
				error: "",
			});
		}
	}
	const repetitions = perfRepetitions();
	for (let repetition = 0; repetition < repetitions; repetition++) {
		for (let k = 0; k < entries.length; k++) {
			const entry = entries[repetition % 2 == 0 ? k : entries.length - 1 - k];
			record(cells, entry, runScenario(entry.scenario), repetition as int32);
		}
	}
	const uptimeEnd = try commandOutput("uptime", []);
	const lines: string[] = [];
	let green = true;
	for (const cell of cells) {
		lines.push(cellLine(cell, uptimeStart, uptimeEnd, binary));
		if (cell.error != "" || cell.values.length == 0) green = false;
	}
	const target = env.get("LSP_PERF_OUT");
	if (target == "") {
		for (const line of lines) console.log(line);
	} else if (!writeFile(target, lines.join("\n") + "\n").ok) {
		return Result.err(`cannot write ${target}`);
	}
	return Result.ok(green);
}

function perfMain(): int32 {
	const ran = perfRun();
	if (!ran.ok) {
		console.log(`lsp-perf: ${ran.error}`);
		return 1;
	}
	return ran.value ? 0 : 1;
}

function main(): int32 {
	ensureDir(OUT);
	ensureDir(NEUTRAL);
	console.log(`lsp-replay: compiler under test = ${MSC}`);
	let passes = 0;
	let fails = 0;
	for (const scenario of lspScenarios()) {
		const failure = runScenario(scenario).failure;
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

process.exit(PERF ? perfMain() : main());
