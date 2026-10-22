// LSP replay scenarios as data: each names its drains and checks a transcript,
// so the in-memory driver and a real-process driver run the same cases.

import { lspFormatMessage, lspJsonString, lspPathToUri } from "./protocol";
import { lspSplitFrames } from "./transport";
import { parseJson } from "std/serialize/json/parser";
import { JsonKind, JsonValue } from "std/serialize/json/types";
import { getDynamicField, at, asInt32 } from "std/serialize/json/accessors";
import { jsonNull } from "std/serialize/json/builder";
import { ensureDir, writeFile } from "std/fs";
import { dirname } from "std/fs/path";

export class LspReplay {
	messages: JsonValue[];
	exitCode: int32;
	drainsConsumed: int32;
}

export type LspBatching = "exact" | "any";

export interface LspProbe {
	uri: string;
	line: int32;
	character: int32;
}

// After each drain index in afterDrains the open documents are a checkpoint: a process
// driver compares the session there with a fresh server and with batch checking,
// asking hover and definition at every probe.
export interface LspCheckpoints {
	afterDrains: int32[];
	probes: LspProbe[];
}

export interface LspProjectFile {
	path: string;
	text: string;
}

// A scenario with a project runs inside a directory holding these files; every
// PROJECT_URI in its drains and transcript names that directory.
export interface LspScenario {
	name: string;
	batching: LspBatching;
	drains: string[][];
	check: (r: LspReplay) => string;
	checkAnyBatching: ((r: LspReplay) => string) | null;
	checkpoints: LspCheckpoints | null;
	project: LspProjectFile[] | null;
}

export const PROJECT_URI = "file:///lspwire/";

export function projectUri(dir: string): string {
	return `${lspPathToUri(dir)}/`;
}

// Every frame of `wire` with `from` replaced by `to`, framed again.
export function replaceInFrames(wire: string, from: string, to: string): string {
	let out = "";
	for (const body of lspSplitFrames(wire)) out += lspFormatMessage(body.replaceAll(from, to));
	return out;
}

// Writes the project files under dir; returns the drains with PROJECT_URI moved there.
export function materialiseProject(files: LspProjectFile[], drains: string[][], dir: string): Result<string[][], string> {
	for (const file of files) {
		const path = `${dir}/${file.path}`;
		const parent = dirname(path);
		if (!ensureDir(parent).ok) return Result.err(`cannot create ${parent}`);
		const written = writeFile(path, file.text);
		if (!written.ok) return Result.err(`cannot write ${path}`);
	}
	const moved: string[][] = [];
	for (const drain of drains) {
		const frames: string[] = [];
		for (const frame of drain) frames.push(replaceInFrames(frame, PROJECT_URI, projectUri(dir)));
		moved.push(frames);
	}
	return Result.ok(moved);
}

export function lspTranscript(output: string, exitCode: int32, drainsConsumed: int32): LspReplay {
	const messages: JsonValue[] = [];
	for (const body of lspSplitFrames(output)) {
		const parsed = parseJson(body);
		if (!parsed.ok) throw new Error("server frame is not JSON: " + body);
		messages.push(parsed.value);
	}
	return { messages, exitCode, drainsConsumed };
}

// ===== Drain builders =====

export function frames(bodies: string[]): string[] {
	const out: string[] = [];
	for (const body of bodies) out.push(lspFormatMessage(body));
	return out;
}

export function request(idJson: string, method: string, params: string): string {
	return `{"jsonrpc":"2.0","id":${idJson},"method":${lspJsonString(method)},"params":${params}}`;
}

export function notification(method: string, params: string): string {
	return `{"jsonrpc":"2.0","method":${lspJsonString(method)},"params":${params}}`;
}

export function initializeDrain(): string[] {
	return frames([request("1", "initialize", "{}"), notification("initialized", "{}")]);
}

export function openParams(uri: string, text: string): string {
	return `{"textDocument":{"uri":${lspJsonString(uri)},"languageId":"metascript","version":1,"text":${lspJsonString(text)}}}`;
}

export function changeParams(uri: string, version: int32, text: string): string {
	return `{"textDocument":{"uri":${lspJsonString(uri)},"version":${version}},"contentChanges":[{"text":${lspJsonString(text)}}]}`;
}

export function positionParams(uri: string, line: int32, character: int32): string {
	return `{"textDocument":{"uri":${lspJsonString(uri)}},"position":{"line":${line},"character":${character}}}`;
}

const BAD_VALUE = "export const value: int32 = \"wrong\";";
const GOOD_VALUE = "export const value: int32 = 42;";
const NOT_ASSIGNABLE = "Type 'string' is not assignable to type 'int32'";
const TWO_CONSTS = "const a = 1;\nconst b = a;";

// ===== Transcript readers =====
// Every reader is total: a missing message or field reads as a value the
// check reports, so a check names the first wrong field instead of throwing.

export function idKey(id: JsonValue): string {
	return match (id.kind) {
		JsonKind.Int => "n:" + id.intVal,
		JsonKind.String => "s:" + id.strVal,
		_ => "",
	};
}

export function hasKey(m: JsonValue, key: string): boolean {
	return m.kind == JsonKind.Object && m.keys.indexOf(key) >= 0;
}

function render(v: JsonValue): string {
	return match (v.kind) {
		JsonKind.Null => "null",
		JsonKind.Bool => v.boolVal ? "true" : "false",
		JsonKind.Number => "" + v.numVal,
		JsonKind.Int => "" + v.intVal,
		JsonKind.String => lspJsonString(v.strVal),
		JsonKind.Array => "array",
		JsonKind.Object => "object",
	};
}

function field(m: JsonValue, path: string): string {
	let v = m;
	for (const key of path.split(".")) {
		if (!hasKey(v, key)) return "absent";
		v = v.getDynamicField(key);
	}
	return render(v);
}

function messageAt(r: LspReplay, index: int32): JsonValue {
	return index < r.messages.length ? r.messages[index] : jsonNull();
}

function answersTo(r: LspReplay, key: string): JsonValue[] {
	const found: JsonValue[] = [];
	for (const m of r.messages) {
		if (idKey(m.getDynamicField("id")) == key) found.push(m);
	}
	return found;
}

function onlyAnswer(r: LspReplay, key: string): Result<JsonValue, string> {
	const found = answersTo(r, key);
	if (found.length != 1) return Result.err("expected one answer to " + key + ", got " + found.length);
	return Result.ok(found[0]);
}

function answerField(r: LspReplay, key: string, path: string): string {
	const answer = onlyAnswer(r, key);
	if (!answer.ok) return answer.error;
	return field(answer.value, path);
}

function published(r: LspReplay, uri: string): JsonValue[] {
	const found: JsonValue[] = [];
	for (const m of r.messages) {
		if (field(m, "method") == lspJsonString("textDocument/publishDiagnostics")
			&& field(m, "params.uri") == lspJsonString(uri)) {
			found.push(m.getDynamicField("params").getDynamicField("diagnostics"));
		}
	}
	return found;
}

function publishedCounts(r: LspReplay, uri: string): string {
	const counts: string[] = [];
	for (const diagnostics of published(r, uri)) {
		counts.push(diagnostics.kind == JsonKind.Array ? "" + diagnostics.items.length : render(diagnostics));
	}
	return "[" + counts.join(",") + "]";
}

function finalDiagnosticCount(r: LspReplay, uri: string): string {
	const all = published(r, uri);
	if (all.length == 0) return "no publish";
	const last = all[all.length - 1];
	return last.kind == JsonKind.Array ? "" + last.items.length : render(last);
}

function diagnosticAt(r: LspReplay, uri: string, publish: int32, index: int32): JsonValue {
	const all = published(r, uri);
	return publish < all.length ? all[publish].at(index) : jsonNull();
}

function spanOf(diagnostic: JsonValue): string {
	const range = diagnostic.getDynamicField("range");
	const start = range.getDynamicField("start");
	const end = range.getDynamicField("end");
	return start.getDynamicField("line").asInt32(-1) + ":" + start.getDynamicField("character").asInt32(-1)
		+ "-" + end.getDynamicField("line").asInt32(-1) + ":" + end.getDynamicField("character").asInt32(-1);
}

// Every diagnostic of the n-th publish for uri as "span severity message", joined by "; ".
function publishedAt(r: LspReplay, uri: string, publish: int32): string {
	const all = published(r, uri);
	if (publish >= all.length) return "no publish " + publish;
	const diagnostics = all[publish];
	if (diagnostics.kind != JsonKind.Array) return render(diagnostics);
	const items: string[] = [];
	for (const d of diagnostics.items) {
		items.push(spanOf(d) + " " + field(d, "severity") + " " + field(d, "message"));
	}
	return "[" + items.join("; ") + "]";
}

function lastPublished(r: LspReplay, uri: string): string {
	const count = published(r, uri).length;
	return count == 0 ? "no publish" : publishedAt(r, uri, (count - 1) as int32);
}

function definitionSpan(r: LspReplay, key: string): string {
	const answer = onlyAnswer(r, key);
	if (!answer.ok) return answer.error;
	const result = answer.value.getDynamicField("result");
	if (result.kind != JsonKind.Array || result.items.length != 1) return "no location";
	return spanOf(result.items[0]);
}

// ===== Checks =====

function sameText(what: string, expected: string, got: string): string {
	return expected == got ? "" : what + ": expected " + expected + ", got " + got;
}

function sameCount(what: string, expected: int32, got: int32): string {
	return expected == got ? "" : what + ": expected " + expected + ", got " + got;
}

function firstFailure(results: string[]): string {
	for (const failure of results) {
		if (failure != "") return failure;
	}
	return "";
}

function requestKeys(drains: string[][]): string[] {
	const keys: string[] = [];
	for (const drain of drains) {
		for (const frame of drain) {
			for (const body of lspSplitFrames(frame)) {
				const parsed = parseJson(body);
				if (parsed.ok && hasKey(parsed.value, "id") && hasKey(parsed.value, "method")) {
					keys.push(idKey(parsed.value.getDynamicField("id")));
				}
			}
		}
	}
	return keys;
}

function everyRequestAnsweredOnce(r: LspReplay, drains: string[][]): string {
	for (const key of requestKeys(drains)) {
		const failure = sameCount("answers to " + key, 1, answersTo(r, key).length);
		if (failure != "") return failure;
	}
	return "";
}

// ===== Scenarios =====

function openWithErrorThenFix(): LspScenario {
	const uri = "file:///lspwire/open.ms";
	return {
		name: "initialize, open with an error, then a fix clears it",
		batching: "any",
		drains: [
			initializeDrain(),
			frames([notification("textDocument/didOpen", openParams(uri, BAD_VALUE))]),
			frames([notification("textDocument/didChange", changeParams(uri, 2, GOOD_VALUE))]),
		],
		check: (r: LspReplay) => firstFailure([
			sameCount("messages", 3, r.messages.length),
			sameText("first message id", "n:1", idKey(messageAt(r, 0).getDynamicField("id"))),
			sameText("textDocumentSync", "1", field(messageAt(r, 0), "result.capabilities.textDocumentSync")),
			sameText("hoverProvider", "true", field(messageAt(r, 0), "result.capabilities.hoverProvider")),
			sameText("diagnostic counts per publish", "[1,0]", publishedCounts(r, uri)),
			sameText("publish 0 message", lspJsonString(NOT_ASSIGNABLE), field(diagnosticAt(r, uri, 0, 0), "message")),
			sameText("publish 0 severity", "1", field(diagnosticAt(r, uri, 0, 0), "severity")),
			sameText("publish 0 span", "0:28-0:29", spanOf(diagnosticAt(r, uri, 0, 0))),
			sameCount("exit code", 0, r.exitCode),
		]),
		checkAnyBatching: null,
		checkpoints: { afterDrains: [1, 2], probes: [{ uri, line: 0, character: 13 }] },
		project: null,
	};
}

function multibyteContentLength(): LspScenario {
	const uri = "file:///lspwire/multibyte.ms";
	return {
		name: "Content-Length counts bytes of a multibyte request body",
		batching: "any",
		drains: [
			initializeDrain(),
			frames([
				notification("textDocument/didOpen", `{"textDocument":{"uri":"${uri}","languageId":"metascript","version":1,"text":"/*é😀*/ export const value: int32 = \\"wrong\\";\\nexport const w = value;"}}`),
				request("\"é😀-1\"", "textDocument/definition", positionParams(uri, 1, 17)),
			]),
		],
		check: (r: LspReplay) => firstFailure([
			sameText("diagnostic counts per publish", "[1]", publishedCounts(r, uri)),
			sameText("publish 0 span", "0:36-0:37", spanOf(diagnosticAt(r, uri, 0, 0))),
			sameText("s:é😀-1 definition", "0:21-0:26", definitionSpan(r, "s:é😀-1")),
		]),
		checkAnyBatching: null,
		checkpoints: { afterDrains: [1], probes: [{ uri, line: 1, character: 17 }, { uri, line: 0, character: 22 }] },
		project: null,
	};
}

function twoEditsOneDrain(): LspScenario {
	const uri = "file:///lspwire/coalesce.ms";
	const drains = [
		initializeDrain(),
		frames([notification("textDocument/didOpen", openParams(uri, GOOD_VALUE))]),
		frames([
			notification("textDocument/didChange", changeParams(uri, 2, BAD_VALUE)),
			notification("textDocument/didChange", changeParams(uri, 3, GOOD_VALUE)),
		]),
	];
	return {
		name: "two edits in one drain publish once",
		batching: "exact",
		drains,
		check: (r: LspReplay) => sameText("diagnostic counts per publish", "[0,0]", publishedCounts(r, uri)),
		checkAnyBatching: (r: LspReplay) => firstFailure([
			everyRequestAnsweredOnce(r, drains),
			sameText("final diagnostic count", "0", finalDiagnosticCount(r, uri)),
		]),
		checkpoints: null,
		project: null,
	};
}

function twoEditsTwoDrains(): LspScenario {
	const uri = "file:///lspwire/split.ms";
	return {
		name: "two edits in two drains publish twice",
		batching: "any",
		drains: [
			initializeDrain(),
			frames([notification("textDocument/didOpen", openParams(uri, GOOD_VALUE))]),
			frames([notification("textDocument/didChange", changeParams(uri, 2, BAD_VALUE))]),
			frames([notification("textDocument/didChange", changeParams(uri, 3, GOOD_VALUE))]),
		],
		check: (r: LspReplay) => firstFailure([
			sameText("diagnostic counts per publish", "[0,1,0]", publishedCounts(r, uri)),
			sameText("publish 1 message", lspJsonString(NOT_ASSIGNABLE), field(diagnosticAt(r, uri, 1, 0), "message")),
		]),
		checkAnyBatching: null,
		checkpoints: { afterDrains: [2], probes: [{ uri, line: 0, character: 13 }] },
		project: null,
	};
}

function requestBetweenEdits(): LspScenario {
	const uri = "file:///lspwire/between.ms";
	return {
		name: "a request between two edits answers the edit before it",
		batching: "any",
		drains: [
			initializeDrain(),
			frames([notification("textDocument/didOpen", openParams(uri, TWO_CONSTS))]),
			frames([
				notification("textDocument/didChange", changeParams(uri, 2, "\n" + TWO_CONSTS)),
				request("3", "textDocument/definition", positionParams(uri, 2, 10)),
				notification("textDocument/didChange", changeParams(uri, 3, "\n\n" + TWO_CONSTS)),
			]),
			frames([request("4", "textDocument/definition", positionParams(uri, 3, 10))]),
		],
		check: (r: LspReplay) => firstFailure([
			sameText("n:3 definition", "1:6-1:7", definitionSpan(r, "n:3")),
			sameText("n:4 definition", "2:6-2:7", definitionSpan(r, "n:4")),
		]),
		checkAnyBatching: null,
		checkpoints: { afterDrains: [3], probes: [{ uri, line: 3, character: 10 }, { uri, line: 1, character: 10 }] },
		project: null,
	};
}

function supersededAndCoalesced(): LspScenario {
	const uri = "file:///lspwire/superseded.ms";
	const document = `{"textDocument":{"uri":${lspJsonString(uri)}}`;
	const drains = [
		initializeDrain(),
		frames([notification("textDocument/didOpen", openParams(uri, GOOD_VALUE))]),
		frames([
			request("5", "textDocument/inlayHint", document + `,"range":{"start":{"line":0,"character":0},"end":{"line":1,"character":0}}}`),
			notification("textDocument/didChange", changeParams(uri, 2, BAD_VALUE)),
			request("6", "textDocument/semanticTokens/full", document + "}"),
			request("7", "textDocument/semanticTokens/full", document + "}"),
		]),
	];
	return {
		name: "superseded and coalesced requests answer ContentModified",
		batching: "exact",
		drains,
		check: (r: LspReplay) => firstFailure([
			sameText("n:5 error.code", "-32801", answerField(r, "n:5", "error.code")),
			sameText("n:6 error.code", "-32801", answerField(r, "n:6", "error.code")),
			sameText("n:7 result.data", "array", answerField(r, "n:7", "result.data")),
			sameText("diagnostic counts per publish", "[0,1]", publishedCounts(r, uri)),
		]),
		checkAnyBatching: (r: LspReplay) => firstFailure([
			everyRequestAnsweredOnce(r, drains),
			sameText("final diagnostic count", "1", finalDiagnosticCount(r, uri)),
		]),
		checkpoints: null,
		project: null,
	};
}

function idsComeBackExactly(): LspScenario {
	const uri = "file:///lspwire/ids.ms";
	return {
		name: "request ids come back exactly, number and string",
		batching: "any",
		drains: [
			initializeDrain(),
			frames([notification("textDocument/didOpen", openParams(uri, TWO_CONSTS))]),
			frames([
				request("0", "textDocument/definition", positionParams(uri, 1, 10)),
				request("42", "textDocument/definition", positionParams(uri, 1, 10)),
				request("\"42\"", "textDocument/definition", positionParams(uri, 1, 10)),
				request("\"req-α\"", "textDocument/hover", positionParams(uri, 1, 6)),
			]),
		],
		check: (r: LspReplay) => firstFailure([
			sameText("n:0 definition", "0:6-0:7", definitionSpan(r, "n:0")),
			sameText("n:42 definition", "0:6-0:7", definitionSpan(r, "n:42")),
			sameText("s:42 definition", "0:6-0:7", definitionSpan(r, "s:42")),
			sameText("s:req-α result", "object", answerField(r, "s:req-α", "result")),
		]),
		checkAnyBatching: null,
		checkpoints: null,
		project: null,
	};
}

function shutdownWaitsForExit(): LspScenario {
	return {
		name: "shutdown answers null and the server waits for exit",
		batching: "any",
		drains: [
			initializeDrain(),
			frames([request("9", "shutdown", "null")]),
			frames([notification("exit", "null")]),
		],
		check: (r: LspReplay) => firstFailure([
			sameCount("messages", 2, r.messages.length),
			sameText("n:9 result", "null", answerField(r, "n:9", "result")),
			sameCount("drains consumed", 3, r.drainsConsumed),
			sameCount("exit code", 0, r.exitCode),
		]),
		checkAnyBatching: null,
		checkpoints: null,
		project: null,
	};
}

function afterShutdown(): LspScenario {
	const uri = "file:///lspwire/aftershutdown.ms";
	return {
		name: "after shutdown a request answers InvalidRequest and a notification is dropped",
		batching: "any",
		drains: [
			initializeDrain(),
			frames([notification("textDocument/didOpen", openParams(uri, GOOD_VALUE))]),
			frames([request("9", "shutdown", "null")]),
			frames([
				request("10", "textDocument/definition", positionParams(uri, 0, 0)),
				notification("textDocument/didChange", changeParams(uri, 2, BAD_VALUE)),
				request("11", "shutdown", "null"),
			]),
			frames([notification("exit", "null")]),
		],
		check: (r: LspReplay) => firstFailure([
			sameText("n:9 result", "null", answerField(r, "n:9", "result")),
			sameText("n:10 error.code", "-32600", answerField(r, "n:10", "error.code")),
			sameText("n:11 error.code", "-32600", answerField(r, "n:11", "error.code")),
			sameText("diagnostic counts per publish", "[0]", publishedCounts(r, uri)),
			sameCount("exit code", 0, r.exitCode),
		]),
		checkAnyBatching: null,
		checkpoints: null,
		project: null,
	};
}

function exitAfterShutdown(): LspScenario {
	const uri = "file:///lspwire/exit.ms";
	return {
		name: "exit after shutdown ends the loop at once with code 0",
		batching: "any",
		drains: [
			initializeDrain(),
			frames([
				request("9", "shutdown", "null"),
				notification("exit", "null"),
				request("10", "textDocument/hover", positionParams(uri, 0, 0)),
			]),
			frames([request("11", "textDocument/hover", positionParams(uri, 0, 0))]),
		],
		check: (r: LspReplay) => firstFailure([
			sameCount("exit code", 0, r.exitCode),
			sameCount("answers to n:10", 0, answersTo(r, "n:10").length),
			sameCount("answers to n:11", 0, answersTo(r, "n:11").length),
			sameCount("drains consumed", 2, r.drainsConsumed),
		]),
		checkAnyBatching: null,
		checkpoints: null,
		project: null,
	};
}

function exitWithoutShutdown(): LspScenario {
	return {
		name: "exit without shutdown ends the loop with code 1",
		batching: "any",
		drains: [initializeDrain(), frames([notification("exit", "null")])],
		check: (r: LspReplay) => firstFailure([
			sameCount("exit code", 1, r.exitCode),
			sameCount("messages", 1, r.messages.length),
		]),
		checkAnyBatching: null,
		checkpoints: null,
		project: null,
	};
}

function closedBeforeExit(): LspScenario {
	return {
		name: "input closed before exit ends the loop with code 0",
		batching: "any",
		drains: [initializeDrain()],
		check: (r: LspReplay) => sameCount("exit code", 0, r.exitCode),
		checkAnyBatching: null,
		checkpoints: null,
		project: null,
	};
}

function bodyCutShort(): LspScenario {
	const body = request("9", "shutdown", "null");
	return {
		name: "a body cut short by EOF is not processed and ends the server with code 1",
		batching: "any",
		drains: [initializeDrain(), ["Content-Length: " + (body.byteLength + 10) + "\r\n\r\n" + body]],
		check: (r: LspReplay) => firstFailure([
			sameCount("answers to n:9", 0, answersTo(r, "n:9").length),
			sameCount("exit code", 1, r.exitCode),
		]),
		checkAnyBatching: null,
		checkpoints: null,
		project: null,
	};
}

function headerCutShort(): LspScenario {
	return {
		name: "a header cut short by EOF ends the server with code 0",
		batching: "any",
		drains: [initializeDrain(), ["Content-Length: 30\r\n"]],
		check: (r: LspReplay) => firstFailure([
			sameCount("messages", 1, r.messages.length),
			sameCount("exit code", 0, r.exitCode),
		]),
		checkAnyBatching: null,
		checkpoints: null,
		project: null,
	};
}

function cancelledInDrain(): LspScenario {
	const uri = "file:///lspwire/cancel.ms";
	const drains = [
		initializeDrain(),
		frames([notification("textDocument/didOpen", openParams(uri, TWO_CONSTS))]),
		frames([
			request("4", "textDocument/definition", positionParams(uri, 1, 10)),
			request("\"four\"", "textDocument/definition", positionParams(uri, 1, 10)),
			request("5", "textDocument/definition", positionParams(uri, 1, 10)),
			notification("$/cancelRequest", "{\"id\":4}"),
			notification("$/cancelRequest", "{\"id\":\"four\"}"),
			notification("$/cancelRequest", "{\"id\":99}"),
		]),
		frames([request("6", "textDocument/definition", positionParams(uri, 1, 10))]),
		frames([notification("$/cancelRequest", "{\"id\":6}")]),
	];
	return {
		name: "a cancelled request still in the drain answers RequestCancelled",
		batching: "exact",
		drains,
		check: (r: LspReplay) => firstFailure([
			sameText("n:4 result", "absent", answerField(r, "n:4", "result")),
			sameText("n:4 error.code", "-32800", answerField(r, "n:4", "error.code")),
			sameText("n:4 error.message", lspJsonString("RequestCancelled"), answerField(r, "n:4", "error.message")),
			sameText("s:four result", "absent", answerField(r, "s:four", "result")),
			sameText("s:four error.code", "-32800", answerField(r, "s:four", "error.code")),
			sameText("s:four error.message", lspJsonString("RequestCancelled"), answerField(r, "s:four", "error.message")),
			sameText("n:5 definition", "0:6-0:7", definitionSpan(r, "n:5")),
			sameText("n:6 definition", "0:6-0:7", definitionSpan(r, "n:6")),
			sameCount("answers to n:99", 0, answersTo(r, "n:99").length),
		]),
		checkAnyBatching: (r: LspReplay) => firstFailure([
			everyRequestAnsweredOnce(r, drains),
			sameText("final diagnostic count", "0", finalDiagnosticCount(r, uri)),
		]),
		checkpoints: null,
		project: null,
	};
}

// The oracles below are written from the source text: UTF-16 columns counted by hand.

const MB_LINE = "/*é😀*/ export const value: int32 = \"wrong\";";
const MB_USE = "export const w = value;";

function positionEditsShiftRanges(): LspScenario {
	const uri = "file:///lspwire/shift.ms";
	const shifted = "// ñ😀\n/*é😀*/ /*😀*/ export const value: int32 = \"wrong\";\n" + MB_USE;
	const fixed = "// ñ😀\n/*é😀*/ /*😀*/ export const value: int32 = 42;\n" + MB_USE;
	const notAssignable = lspJsonString(NOT_ASSIGNABLE);
	const drains = [
		initializeDrain(),
		frames([
			notification("textDocument/didOpen", openParams(uri, MB_LINE + "\n" + MB_USE)),
			request("11", "textDocument/definition", positionParams(uri, 1, 17)),
		]),
		frames([
			notification("textDocument/didChange", changeParams(uri, 2, shifted)),
			request("12", "textDocument/definition", positionParams(uri, 2, 17)),
		]),
		frames([
			notification("textDocument/didChange", changeParams(uri, 3, fixed)),
			request("13", "textDocument/definition", positionParams(uri, 2, 17)),
		]),
	];
	return {
		name: "position edits past non-ASCII text shift the diagnostic and the definition, a fix clears it",
		batching: "any",
		drains,
		check: (r: LspReplay) => firstFailure([
			everyRequestAnsweredOnce(r, drains),
			sameText("publish 0", "[0:36-0:37 1 " + notAssignable + "]", publishedAt(r, uri, 0)),
			sameText("n:11 definition", "0:21-0:26", definitionSpan(r, "n:11")),
			sameText("publish 1", "[1:43-1:44 1 " + notAssignable + "]", publishedAt(r, uri, 1)),
			sameText("n:12 definition", "1:28-1:33", definitionSpan(r, "n:12")),
			sameText("publish 2", "[]", publishedAt(r, uri, 2)),
			sameText("n:13 definition", "1:28-1:33", definitionSpan(r, "n:13")),
		]),
		checkAnyBatching: null,
		checkpoints: {
			afterDrains: [1, 2, 3],
			probes: [{ uri, line: 2, character: 17 }, { uri, line: 1, character: 17 }, { uri, line: 1, character: 30 }],
		},
		project: null,
	};
}

function dependencyEditsRecheckDependent(): LspScenario {
	const dep = "file:///lspwire/dep/b.ms";
	const user = "file:///lspwire/dep/a.ms";
	const depInt = "export const value: int32 = 42;";
	const depString = "export const value: string = \"x\";";
	const wantsString = "import { value } from \"./b\";\nconst s: string = value;\nexport const t = s;";
	const wantsInt = "import { value } from \"./b\";\nconst n: int32 = value;\nexport const t = n;";
	return {
		name: "a dependency edit re-checks the dependent and clears or raises its diagnostic",
		batching: "any",
		drains: [
			initializeDrain(),
			frames([notification("textDocument/didOpen", openParams(dep, depInt))]),
			frames([notification("textDocument/didOpen", openParams(user, wantsString))]),
			frames([notification("textDocument/didChange", changeParams(dep, 2, depString))]),
			frames([notification("textDocument/didChange", changeParams(user, 2, wantsInt))]),
			frames([notification("textDocument/didChange", changeParams(dep, 3, depInt))]),
		],
		check: (r: LspReplay) => firstFailure([
			sameText("a.ms publish 0 start and message", "1:18 " + lspJsonString("Type 'int32' is not assignable to type 'string'"),
				spanOf(diagnosticAt(r, user, 0, 0)).split("-")[0] + " " + field(diagnosticAt(r, user, 0, 0), "message")),
			sameText("a.ms after b.ms exports a string", "[]", publishedAt(r, user, 1)),
			sameText("a.ms publish 2 start and message", "1:17 " + lspJsonString("Type 'string' is not assignable to type 'int32'"),
				spanOf(diagnosticAt(r, user, 2, 0)).split("-")[0] + " " + field(diagnosticAt(r, user, 2, 0), "message")),
			sameText("a.ms after b.ms exports an int32 again", "[]", lastPublished(r, user)),
			sameText("b.ms last publish", "[]", lastPublished(r, dep)),
		]),
		checkAnyBatching: null,
		checkpoints: { afterDrains: [2, 3, 4, 5], probes: [{ uri: user, line: 1, character: 18 }, { uri: user, line: 0, character: 9 }] },
		project: null,
	};
}

function cancelledWorkDoesNotPoison(): LspScenario {
	const uri = "file:///lspwire/cancelok.ms";
	const good = "// café ☕\nexport const value: int32 = 42;\nexport const w = value;";
	const bad = "// café ☕\nexport const value: int32 = \"wrong\";\nexport const w = value;";
	const drains = [
		initializeDrain(),
		frames([notification("textDocument/didOpen", openParams(uri, good))]),
		frames([
			notification("textDocument/didChange", changeParams(uri, 2, bad)),
			request("20", "textDocument/hover", positionParams(uri, 2, 17)),
			request("21", "textDocument/definition", positionParams(uri, 2, 17)),
			notification("$/cancelRequest", "{\"id\":20}"),
			notification("$/cancelRequest", "{\"id\":21}"),
		]),
		frames([request("22", "textDocument/definition", positionParams(uri, 2, 17))]),
		frames([
			notification("textDocument/didChange", changeParams(uri, 3, good)),
			notification("$/cancelRequest", "{\"id\":99}"),
		]),
	];
	const afterCancel = (r: LspReplay) => firstFailure([
		everyRequestAnsweredOnce(r, drains),
		sameText("publish 1", "[1:28-1:29 1 " + lspJsonString(NOT_ASSIGNABLE) + "]", publishedAt(r, uri, 1)),
		sameText("n:22 definition", "1:13-1:18", definitionSpan(r, "n:22")),
		sameText("last publish", "[]", lastPublished(r, uri)),
	]);
	return {
		name: "cancelled requests do not poison the checks after them",
		batching: "exact",
		drains,
		check: (r: LspReplay) => firstFailure([
			sameText("n:20 error.code", "-32800", answerField(r, "n:20", "error.code")),
			sameText("n:21 error.code", "-32800", answerField(r, "n:21", "error.code")),
			sameText("diagnostic counts per publish", "[0,1,0]", publishedCounts(r, uri)),
			afterCancel(r),
		]),
		checkAnyBatching: afterCancel,
		checkpoints: { afterDrains: [2, 3, 4], probes: [{ uri, line: 2, character: 17 }, { uri, line: 1, character: 14 }] },
		project: null,
	};
}

function unusedImportWarnsInEditorAndBatch(): LspScenario {
	const uri = "file:///lspwire/warn.ms";
	const text = "import { exists } from \"std/fs\";\nexport const v: int32 = 1;";
	return {
		name: "an unused import warns in the editor and in batch checking",
		batching: "any",
		drains: [initializeDrain(), frames([notification("textDocument/didOpen", openParams(uri, text))])],
		check: (r: LspReplay) => sameText("publish 0",
			"[0:9-0:15 2 " + lspJsonString("'exists' is imported but never used") + "]",
			publishedAt(r, uri, 0)),
		checkAnyBatching: null,
		checkpoints: { afterDrains: [1], probes: [{ uri, line: 0, character: 10 }] },
		project: null,
	};
}

const WHEN_FAST = "let n: int32 = 0;\nwhen (fast) { n = 1; } else { n = \"slow\"; }\nconsole.log(n);\n";
const HELLO = "export function hello(): int32 { return 7; }\n";

function buildConfigReachesEditor(): LspScenario {
	const globals = PROJECT_URI + "globals.ms";
	const defines = PROJECT_URI + "defines.ms";
	const deps = PROJECT_URI + "deps.ms";
	const build = "const config = { globalImports: [\"./helper\"], defines: { fast: true }, deps: { \"lib\": \"file:./deplib\" } };\nexport default config;\n";
	return {
		name: "build.ms config reaches the editor as it reaches batch checking",
		batching: "any",
		drains: [
			initializeDrain(),
			frames([
				notification("textDocument/didOpen", openParams(globals, "const n: int32 = hello();\nconsole.log(n);\n")),
				notification("textDocument/didOpen", openParams(defines, WHEN_FAST)),
				notification("textDocument/didOpen", openParams(deps, "import { libVal } from \"lib/val\";\nconst n: int32 = libVal();\nconsole.log(n);\n")),
			]),
		],
		check: (r: LspReplay) => firstFailure([
			sameText("globals.ms publish 0", "[]", publishedAt(r, globals, 0)),
			sameText("defines.ms publish 0", "[]", publishedAt(r, defines, 0)),
			sameText("deps.ms publish 0", "[]", publishedAt(r, deps, 0)),
		]),
		checkAnyBatching: null,
		checkpoints: { afterDrains: [1], probes: [{ uri: globals, line: 0, character: 18 }, { uri: deps, line: 1, character: 18 }] },
		project: [
			{ path: "build.ms", text: build },
			{ path: "helper.ms", text: HELLO },
			{ path: "deplib/val.ms", text: "export function libVal(): int32 { return 3; }\n" },
		],
	};
}

function twoProjectsKeepTheirConfig(): LspScenario {
	const fast = PROJECT_URI + "fast/defines.ms";
	const greet = PROJECT_URI + "greet/globals.ms";
	const greetText = "let n: int32 = hello();\nwhen (fast) { n = \"leaked\"; }\nconsole.log(n);\n";
	return {
		name: "two projects in one session each keep their own build.ms",
		batching: "any",
		drains: [
			initializeDrain(),
			frames([notification("textDocument/didOpen", openParams(fast, WHEN_FAST))]),
			frames([notification("textDocument/didOpen", openParams(greet, greetText))]),
			frames([
				notification("textDocument/didChange", changeParams(fast, 2, WHEN_FAST + "// edited\n")),
				notification("textDocument/didChange", changeParams(greet, 2, greetText + "// edited\n")),
			]),
		],
		check: (r: LspReplay) => firstFailure([
			sameText("fast/defines.ms publish 0", "[]", publishedAt(r, fast, 0)),
			sameText("greet/globals.ms publish 0", "[]", publishedAt(r, greet, 0)),
			sameText("fast/defines.ms last publish", "[]", lastPublished(r, fast)),
			sameText("greet/globals.ms last publish", "[]", lastPublished(r, greet)),
		]),
		checkAnyBatching: null,
		checkpoints: { afterDrains: [2, 3], probes: [{ uri: greet, line: 0, character: 16 }] },
		project: [
			{ path: "fast/build.ms", text: "const config = { defines: { fast: true } };\nexport default config;\n" },
			{ path: "greet/build.ms", text: "const config = { globalImports: [\"./helper\"] };\nexport default config;\n" },
			{ path: "greet/helper.ms", text: HELLO },
		],
	};
}

function globalImportMacroExpands(): LspScenario {
	const uri = PROJECT_URI + "twice.ms";
	const mac = "import { Node } from \"std/meta\";\nexport macro twice(n: Node): Node {\n\treturn quote { (${n} * 2) };\n}\n";
	return {
		name: "a macro from a build.ms global import expands in the editor",
		batching: "any",
		drains: [
			initializeDrain(),
			frames([notification("textDocument/didOpen", openParams(uri, "const n: int32 = twice(3);\nconsole.log(n);\n"))]),
		],
		check: (r: LspReplay) => sameText("twice.ms publish 0", "[]", publishedAt(r, uri, 0)),
		checkAnyBatching: null,
		checkpoints: { afterDrains: [1], probes: [{ uri, line: 0, character: 18 }] },
		project: [
			{ path: "build.ms", text: "const config = { globalImports: [\"./mac\"] };\nexport default config;\n" },
			{ path: "mac.ms", text: mac },
		],
	};
}

function sharedDepResolvesPerProject(): LspScenario {
	const aPlain = PROJECT_URI + "a/plain.ms";
	const aGeneric = PROJECT_URI + "a/generic.ms";
	const bPlain = PROJECT_URI + "b/plain.ms";
	const bGeneric = PROJECT_URI + "b/generic.ms";
	const plain = "import { v } from \"lib/lib\";\nconst n: int32 = v;\nconsole.log(n);\n";
	const generic = "import { pick } from \"lib/lib\";\nconst n: int32 = pick<int32>(3);\nconsole.log(n);\n";
	const build = "const config = { deps: { \"lib\": \"file:../shared\", \"cfg\": \"file:./cfg\" } };\nexport default config;\n";
	const lib = "import { confValue } from \"cfg/conf\";\nexport const v = confValue();\nexport function pick<T>(x: T): int32 {\n\treturn confValue();\n}\n";
	return {
		name: "a dependency shared by two projects resolves through each project's own deps",
		batching: "any",
		drains: [
			initializeDrain(),
			frames([notification("textDocument/didOpen", openParams(aPlain, plain)), notification("textDocument/didOpen", openParams(aGeneric, generic))]),
			frames([notification("textDocument/didOpen", openParams(bPlain, plain)), notification("textDocument/didOpen", openParams(bGeneric, generic))]),
			frames([
				notification("textDocument/didChange", changeParams(aPlain, 2, plain + "// edited\n")),
				notification("textDocument/didChange", changeParams(aGeneric, 2, generic + "// edited\n")),
			]),
		],
		check: (r: LspReplay) => firstFailure([
			sameText("a/plain.ms publish 0", "[]", publishedAt(r, aPlain, 0)),
			sameText("a/generic.ms publish 0", "[]", publishedAt(r, aGeneric, 0)),
			publishedAt(r, bPlain, 0) == "[]" ? "b/plain.ms publish 0: expected b's string confValue to refuse int32, got []" : "",
			publishedAt(r, bGeneric, 0) == "[]" ? "b/generic.ms publish 0: expected b's string confValue to refuse int32, got []" : "",
			sameText("a/plain.ms last publish", "[]", lastPublished(r, aPlain)),
			sameText("a/generic.ms last publish", "[]", lastPublished(r, aGeneric)),
		]),
		checkAnyBatching: null,
		checkpoints: { afterDrains: [2, 3], probes: [{ uri: bPlain, line: 1, character: 17 }] },
		project: [
			{ path: "shared/lib.ms", text: lib },
			{ path: "a/build.ms", text: build },
			{ path: "a/cfg/conf.ms", text: "export function confValue(): int32 { return 1; }\n" },
			{ path: "b/build.ms", text: build },
			{ path: "b/cfg/conf.ms", text: "export function confValue(): string { return \"b\"; }\n" },
		],
	};
}

const SHAPES = "export class Box {\n\tv: int32;\n\tconstructor(v: int32) {\n\t\tthis.v = v;\n\t}\n}\nexport class Holder<T> {\n\titem: T;\n\tconstructor(item: T) {\n\t\tthis.item = item;\n\t}\n}\nexport function takeBox(b: Box): int32 {\n\treturn b.v;\n}\n";
const SHAPE_MAKERS = "export function mkBox(): Box {\n\treturn new Box(4);\n}\nexport function mkHolder(): Holder<Box> {\n\treturn new Holder<Box>(new Box(5));\n}\nexport function readBox(b: Box): int32 {\n\treturn b.v;\n}\n";
const SHAPE_USER = "import { Box, Holder, takeBox } from \"./shapes\";\nconst b: Box = mkBox();\nconst h: Holder<Box> = mkHolder();\nconsole.log(takeBox(b) + readBox(new Box(7)) + h.item.v);\n";

function globalImportSharesClassIdentity(): LspScenario {
	const uri = PROJECT_URI + "use.ms";
	return {
		name: "a class reached through a build.ms global import is the class its importer names",
		batching: "any",
		drains: [
			initializeDrain(),
			frames([notification("textDocument/didOpen", openParams(uri, SHAPE_USER))]),
			frames([notification("textDocument/didChange", changeParams(uri, 2, SHAPE_USER + "// edited\n"))]),
		],
		check: (r: LspReplay) => firstFailure([
			sameText("use.ms publish 0", "[]", publishedAt(r, uri, 0)),
			sameText("use.ms last publish", "[]", lastPublished(r, uri)),
		]),
		checkAnyBatching: null,
		checkpoints: { afterDrains: [1, 2], probes: [{ uri, line: 1, character: 16 }] },
		project: [
			{ path: "build.ms", text: "const config = { globalImports: [\"./makers\"] };\nexport default config;\n" },
			{ path: "makers.ms", text: "import { Box, Holder } from \"./shapes\";\n" + SHAPE_MAKERS },
			{ path: "shapes.ms", text: SHAPES },
		],
	};
}

function globalImportSharesMacroModuleIdentity(): LspScenario {
	const uri = PROJECT_URI + "use.ms";
	const twice = "import { Node } from \"std/meta\";\nexport macro twice(n: Node): Node {\n\treturn quote { (${n} * 2) };\n}\n";
	const user = "import { Box, Holder, takeBox, twice } from \"./shapes\";\nconst h: Holder<Box> = mkHolder();\nconsole.log(takeBox(h.item) + readBox(mkBox()) + twice(1));\n";
	return {
		name: "a generic class from a macro module reached through a build.ms global import keeps its identity",
		batching: "any",
		drains: [
			initializeDrain(),
			frames([notification("textDocument/didOpen", openParams(uri, user))]),
		],
		check: (r: LspReplay) => sameText("use.ms publish 0", "[]", publishedAt(r, uri, 0)),
		checkAnyBatching: null,
		checkpoints: { afterDrains: [1], probes: [{ uri, line: 1, character: 26 }] },
		project: [
			{ path: "build.ms", text: "const config = { globalImports: [\"./makers\"] };\nexport default config;\n" },
			{ path: "makers.ms", text: "import { Box, Holder } from \"./shapes\";\n" + SHAPE_MAKERS },
			{ path: "shapes.ms", text: twice + SHAPES },
		],
	};
}

function containsText(what: string, needle: string, got: string): string {
	return got.includes(needle) ? "" : what + ": expected to contain " + needle + ", got " + got;
}

function lacksText(what: string, needle: string, got: string): string {
	return got.includes(needle) ? what + ": expected no " + needle + ", got " + got : "";
}

const MAKERS_PROJECT: LspProjectFile[] = [
	{ path: "build.ms", text: "const config = { globalImports: [\"./makers\"] };\nexport default config;\n" },
	{ path: "makers.ms", text: "import { Box, Holder } from \"./shapes\";\n" + SHAPE_MAKERS },
	{ path: "shapes.ms", text: SHAPES },
];

function globalImportEditReachesItsUsers(): LspScenario {
	const uri = PROJECT_URI + "use.ms";
	const makers = PROJECT_URI + "makers.ms";
	const makersText = "import { Box, Holder } from \"./shapes\";\n" + SHAPE_MAKERS;
	return {
		name: "an edit to a build.ms global import reaches the modules that use its names",
		batching: "any",
		drains: [
			initializeDrain(),
			frames([notification("textDocument/didOpen", openParams(uri, "console.log(readBox(mkBox()));\n"))]),
			frames([notification("textDocument/didOpen", openParams(makers, makersText))]),
			frames([notification("textDocument/didChange", changeParams(makers, 2, makersText.replace("function mkBox(", "function mkBoxRenamed(")))]),
		],
		check: (r: LspReplay) => firstFailure([
			sameText("use.ms publish 0", "[]", publishedAt(r, uri, 0)),
			containsText("use.ms after makers.ms renames mkBox", "Undefined variable 'mkBox'", lastPublished(r, uri)),
		]),
		checkAnyBatching: null,
		checkpoints: { afterDrains: [1, 3], probes: [{ uri, line: 0, character: 22 }] },
		project: MAKERS_PROJECT,
	};
}

function globalImportClosureSeesNoGlobals(): LspScenario {
	const uri = PROJECT_URI + "shapes.ms";
	return {
		name: "a module a build.ms global import reaches does not see the global import, as in batch checking",
		batching: "any",
		drains: [
			initializeDrain(),
			frames([notification("textDocument/didOpen", openParams(uri, SHAPES + "export function viaGlobal(): int32 {\n\treturn readBox(mkBox());\n}\n"))]),
		],
		check: (r: LspReplay) => containsText("shapes.ms publish 0", "Undefined variable 'readBox'", publishedAt(r, uri, 0)),
		checkAnyBatching: null,
		checkpoints: { afterDrains: [1], probes: [{ uri, line: 16, character: 10 }] },
		project: MAKERS_PROJECT,
	};
}

function genericReadsItsModuleConst(): LspScenario {
	const uri = PROJECT_URI + "use.ms";
	const user = "import { capped, nested, cappedByConsts } from \"./rows\";\nconsole.log(capped<int32>([1, 2]) + nested<string>([\"a\"]) + cappedByConsts<int32>([3]));\n";
	const rows = "import { otherLimit } from \"./consts\";\nconst limit = 32;\nexport function capped<T>(items: T[]): number {\n\treturn Math.min(limit, items.length);\n}\nexport function nested<T>(items: T[]): number {\n\treturn capped<T>(items);\n}\nexport function cappedByConsts<T>(items: T[]): number {\n\treturn Math.min(otherLimit, items.length);\n}\n";
	return {
		name: "a generic instantiated from an importer reads its module's inferred const",
		batching: "any",
		drains: [
			initializeDrain(),
			frames([notification("textDocument/didOpen", openParams(uri, user))]),
		],
		check: (r: LspReplay) => lacksText("use.ms publish 0", "instantiation", publishedAt(r, uri, 0)),
		checkAnyBatching: null,
		checkpoints: { afterDrains: [1], probes: [{ uri, line: 1, character: 14 }] },
		project: [
			{ path: "rows.ms", text: rows },
			{ path: "consts.ms", text: "export const otherLimit = 16;\n" },
		],
	};
}

const EACH_MODULE = "import { helper } from \"./node\";\nimport { twice } from \"./mac\";\nexport function each<T>(x: T): number {\n\treturn helper(twice(1));\n}\n";
const EACH_MACRO = "import { Node } from \"std/meta\";\nexport macro twice(n: Node): Node {\n\treturn quote { (${n} * 2) };\n}\n";
const EACH_HELPER = "export function helper(n: number): number {\n\treturn n;\n}\n";

// each.ms imports a macro module, so the editor binds it apart from the check that imports it.
function genericFromMacroImporterReadsItsImports(throughGlobal: boolean): LspScenario {
	const uri = PROJECT_URI + "use.ms";
	const from = throughGlobal ? "./g" : "./each";
	const user = `import { each } from "${from}";\nconst n = each<string>("a");\nconsole.log(n);\n`;
	const project: LspProjectFile[] = [
		{ path: "each.ms", text: EACH_MODULE },
		{ path: "node.ms", text: EACH_HELPER },
		{ path: "mac.ms", text: EACH_MACRO },
	];
	if (throughGlobal) {
		project.push({ path: "g.ms", text: "export { each } from \"./each\";\n" });
		project.push({ path: "build.ms", text: "const config = { globalImports: [\"./g\"] };\nexport default config;\n" });
	}
	const reached = throughGlobal ? " reached through a build.ms global import" : "";
	return {
		name: `a generic from a module that imports a macro${reached} reads that module's imports`,
		batching: "any",
		drains: [
			initializeDrain(),
			frames([notification("textDocument/didOpen", openParams(uri, user))]),
			frames([notification("textDocument/didChange", changeParams(uri, 2, user.replace("\"a\"", "\"b\"")))]),
		],
		check: (r: LspReplay) => firstFailure([
			lacksText("use.ms publish 0", "instantiation", publishedAt(r, uri, 0)),
			lacksText("use.ms last publish", "instantiation", lastPublished(r, uri)),
		]),
		checkAnyBatching: null,
		checkpoints: { afterDrains: [1, 2], probes: [{ uri, line: 1, character: 10 }] },
		project,
	};
}

function globalImportsSeenInOrder(): LspScenario {
	const uri = PROJECT_URI + "c2.ms";
	const seesFirst = "export function d2(): int32 {\n\treturn f1();\n}\n";
	return {
		name: "a module the second build.ms global import reaches sees the first one only",
		batching: "any",
		drains: [
			initializeDrain(),
			frames([notification("textDocument/didOpen", openParams(uri, seesFirst))]),
			frames([notification("textDocument/didChange", changeParams(uri, 2, seesFirst.replace("f1()", "f2()")))]),
		],
		check: (r: LspReplay) => firstFailure([
			lacksText("c2.ms calling the first global import", "Undefined", publishedAt(r, uri, 0)),
			containsText("c2.ms calling the second global import", "Undefined variable 'f2'", lastPublished(r, uri)),
		]),
		checkAnyBatching: null,
		checkpoints: { afterDrains: [1], probes: [{ uri, line: 1, character: 9 }] },
		project: [
			{ path: "build.ms", text: "const config = { globalImports: [\"./g1\", \"./g2\"] };\nexport default config;\n" },
			{ path: "g1.ms", text: "import { d1 } from \"./c1\";\nexport function f1(): int32 {\n\treturn d1();\n}\n" },
			{ path: "c1.ms", text: "export function d1(): int32 {\n\treturn 1;\n}\n" },
			{ path: "g2.ms", text: "import { d2 } from \"./c2\";\nexport function f2(): int32 {\n\treturn d2() + f1();\n}\n" },
			{ path: "c2.ms", text: seesFirst },
			{ path: "use.ms", text: "console.log(f1() + f2());\n" },
		],
	};
}

function modulePassSurvivesProjectSwitch(): LspScenario {
	const use = PROJECT_URI + "a/use.ms";
	const other = PROJECT_URI + "b/main.ms";
	const pass = "import { Node } from \"std/meta\";\nexport macro keep(mod: Node): Node {\n\treturn mod;\n}\nexport function helper(): int32 {\n\treturn 2;\n}\n";
	return {
		name: "a build.ms module pass still applies after the session checked another project",
		batching: "any",
		drains: [
			initializeDrain(),
			frames([notification("textDocument/didOpen", openParams(use, "console.log(helper());\n"))]),
			frames([notification("textDocument/didOpen", openParams(other, "console.log(1);\n"))]),
			frames([notification("textDocument/didChange", changeParams(use, 2, "console.log(helper() + 1);\n"))]),
		],
		check: (r: LspReplay) => firstFailure([
			sameText("a/use.ms publish 0", "[]", publishedAt(r, use, 0)),
			sameText("a/use.ms after b/main.ms", "[]", lastPublished(r, use)),
		]),
		checkAnyBatching: null,
		checkpoints: { afterDrains: [1, 3], probes: [{ uri: use, line: 0, character: 14 }] },
		project: [
			{ path: "a/build.ms", text: "const config = { globalImports: [{ from: \"./pass\", modulePass: \"keep\" }] };\nexport default config;\n" },
			{ path: "a/pass.ms", text: pass },
			{ path: "b/build.ms", text: "const config = {};\nexport default config;\n" },
		],
	};
}

function scalarText(v: JsonValue): string {
	return match (v.kind) {
		JsonKind.String => v.strVal,
		JsonKind.Int => "" + v.intVal,
		JsonKind.Number => "" + v.numVal,
		_ => "",
	};
}

function answerResult(r: LspReplay, key: string): JsonValue {
	const answer = onlyAnswer(r, key);
	return answer.ok ? answer.value.getDynamicField("result") : jsonNull();
}

function cursorAtEnd(uri: string, text: string): string {
	const lines = text.split("\n");
	const last = lines.length - 1;
	return positionParams(uri, last as int32, lines[last].length as int32);
}

function completionRows(r: LspReplay, key: string): string[] {
	const result = answerResult(r, key);
	if (result.kind != JsonKind.Array) return ["not a completion list: " + render(result)];
	const keyed: string[] = [];
	for (const item of result.items) {
		const label = scalarText(item.getDynamicField("label"));
		const row = label + "|" + scalarText(item.getDynamicField("kind")) + "|" + scalarText(item.getDynamicField("detail"));
		keyed.push(scalarText(item.getDynamicField("sortText")) + "\t" + label + "\t" + row);
	}
	keyed.sort();
	const rows: string[] = [];
	for (const entry of keyed) rows.push(entry.split("\t")[2]);
	return rows;
}

function sameRows(what: string, expected: string[], got: string[]): string {
	return sameText(what, "[" + expected.join(", ") + "]", "[" + got.join(", ") + "]");
}

function sortTextOf(r: LspReplay, key: string, label: string): string {
	const result = answerResult(r, key);
	if (result.kind != JsonKind.Array) return "absent";
	for (const item of result.items) {
		if (scalarText(item.getDynamicField("label")) == label) return scalarText(item.getDynamicField("sortText"));
	}
	return "absent";
}

function sortsBefore(r: LspReplay, key: string, first: string, second: string): string {
	const a = sortTextOf(r, key, first);
	const b = sortTextOf(r, key, second);
	if (a == "absent" || b == "absent" || !(a < b)) {
		return first + " must sort before " + second + ": sortText " + a + " against " + b;
	}
	return "";
}

function signatureSummary(r: LspReplay, key: string): string {
	const result = answerResult(r, key);
	const signatures = result.getDynamicField("signatures");
	if (signatures.kind != JsonKind.Array) return "no signatures: " + render(result);
	const activeSignature = result.getDynamicField("activeSignature").asInt32(-1);
	const active = signatures.at(activeSignature);
	const labels: string[] = [];
	const parameters = active.getDynamicField("parameters");
	if (parameters.kind == JsonKind.Array) {
		for (const parameter of parameters.items) labels.push(scalarText(parameter.getDynamicField("label")));
	}
	return "signatures " + signatures.items.length + ", activeSignature " + activeSignature
		+ ", activeParameter " + result.getDynamicField("activeParameter").asInt32(-1)
		+ ", label " + scalarText(active.getDynamicField("label")) + ", parameters [" + labels.join(", ") + "]";
}

function hoverSummary(r: LspReplay, key: string): string {
	const result = answerResult(r, key);
	if (result.kind != JsonKind.Object) return "no hover: " + render(result);
	return scalarText(result.getDynamicField("contents").getDynamicField("value")) + " @ " + spanOf(result);
}

const SEMANTIC_ROW_TYPES = ["class", "property", "parameter", "function", "variable"];

function semanticRows(r: LspReplay, key: string): string[] {
	const legend = answerResult(r, "n:1").getDynamicField("capabilities").getDynamicField("semanticTokensProvider").getDynamicField("legend");
	const types = legend.getDynamicField("tokenTypes");
	const modifiers = legend.getDynamicField("tokenModifiers");
	const data = answerResult(r, key).getDynamicField("data");
	if (data.kind != JsonKind.Array || types.kind != JsonKind.Array || modifiers.kind != JsonKind.Array) return ["no token data"];
	const rows: string[] = [];
	let line: int32 = 0;
	let col: int32 = 0;
	for (let i = 0; i + 4 < data.items.length; i += 5) {
		const deltaLine = data.items[i].asInt32(0);
		line += deltaLine;
		col = deltaLine == 0 ? col + data.items[i + 1].asInt32(0) : data.items[i + 1].asInt32(0);
		const typeIndex = data.items[i + 3].asInt32(-1);
		const typeName = typeIndex >= 0 && typeIndex < types.items.length ? scalarText(types.items[typeIndex]) : "type#" + typeIndex;
		if (!SEMANTIC_ROW_TYPES.includes(typeName)) continue;
		const bits = data.items[i + 4].asInt32(0);
		const names: string[] = [];
		for (let b = 0; b < modifiers.items.length; b++) {
			if ((bits & (1 << b)) != 0) names.push(scalarText(modifiers.items[b]));
		}
		rows.push(line + ":" + col + "+" + data.items[i + 2].asInt32(0) + " " + typeName + (names.length > 0 ? " " + names.join("+") : ""));
	}
	return rows;
}

const POINT_SOURCE = "interface Point {\n\tx: int32;\n\ty: int32;\n\tlabel?: string;\n}\nconst p: Point = { x: 1, y: 2 };\np.";
const COUNTER_SOURCE = "class Counter {\n\tcount: int32;\n\tlabel: string;\n\tconstructor() {\n\t\tthis.count = 0;\n\t\tthis.label = \"c\";\n\t}\n\tbump(by: int32): int32 {\n\t\treturn this.count + by;\n\t}\n\treset(): void {\n\t\tthis.count = 0;\n\t}\n}\nconst k = new Counter();\nk.";

// Bug: a field answers kind 10 (Property) where the LSP spec's Field is 5, and every item list
// carries an extra `hash` method no TypeScript type has.
export function memberCompletionKindsParked(): LspScenario {
	const point = "file:///lspwire/point.ms";
	const counter = "file:///lspwire/counter.ms";
	return {
		name: "member completion lists exactly the members, fields as Field and methods as Method",
		batching: "any",
		drains: [
			initializeDrain(),
			frames([
				notification("textDocument/didOpen", openParams(point, POINT_SOURCE)),
				notification("textDocument/didOpen", openParams(counter, COUNTER_SOURCE)),
			]),
			frames([
				request("10", "textDocument/completion", cursorAtEnd(point, POINT_SOURCE)),
				request("11", "textDocument/completion", cursorAtEnd(counter, COUNTER_SOURCE)),
			]),
		],
		check: (r: LspReplay) => firstFailure([
			sameRows("p. on an interface value", ["label|5|string | null", "x|5|int32", "y|5|int32"], completionRows(r, "n:10")),
			sameRows("k. on a class instance", ["bump|2|(by: int32) => int32", "count|5|int32", "label|5|string", "reset|2|() => void"], completionRows(r, "n:11")),
		]),
		checkAnyBatching: null,
		checkpoints: null,
		project: null,
	};
}

const SCOPE_SOURCE = "import { exists } from \"std/fs\";\nfunction helper(): int32 {\n\treturn 1;\n}\nconst total = 5;\nfunction run(): void {\n\tconst local = 2;\n\t\n}\n";

// Bug: a const declared earlier in the enclosing function is absent from the scope list, and
// every non-keyword name shares sortText "10", so a local does not sort before an import.
export function scopeCompletionTiersParked(): LspScenario {
	const uri = "file:///lspwire/scope.ms";
	return {
		name: "scope completion sorts locals before imports before keywords",
		batching: "any",
		drains: [
			initializeDrain(),
			frames([notification("textDocument/didOpen", openParams(uri, SCOPE_SOURCE))]),
			frames([request("10", "textDocument/completion", positionParams(uri, 7, 1))]),
		],
		check: (r: LspReplay) => firstFailure([
			sortsBefore(r, "n:10", "local", "exists"),
			sortsBefore(r, "n:10", "local", "helper"),
			sortsBefore(r, "n:10", "exists", "const"),
			sortsBefore(r, "n:10", "helper", "const"),
		]),
		checkAnyBatching: null,
		checkpoints: null,
		project: null,
	};
}

const BOX_SOURCE = "class Box<T> {\n\titem: T;\n\tconstructor(item: T) {\n\t\tthis.item = item;\n\t}\n\tget(): T {\n\t\treturn this.item;\n\t}\n\tput(v: T): void {\n\t\tthis.item = v;\n\t}\n}\nconst b = new Box<string>(\"a\");\nb.";
const OPTIONAL_SOURCE = "interface Cfg {\n\tport: int32;\n\thost: string;\n}\nfunction find(): Cfg | null {\n\treturn null;\n}\nconst c = find();\nc?.";

// Bugs: `b.` on Box<string> lists no `item` field and shows the members with T unsubstituted
// (`() => T`, `(v: T) => void`); `c?.` on `Cfg | null` lists only `hash`, not port and host.
export function genericAndOptionalCompletionParked(): LspScenario {
	const box = "file:///lspwire/box.ms";
	const optional = "file:///lspwire/optional.ms";
	return {
		name: "completion after . on a generic instance and after ?. on an optional value",
		batching: "any",
		drains: [
			initializeDrain(),
			frames([
				notification("textDocument/didOpen", openParams(box, BOX_SOURCE)),
				notification("textDocument/didOpen", openParams(optional, OPTIONAL_SOURCE)),
			]),
			frames([
				request("10", "textDocument/completion", cursorAtEnd(box, BOX_SOURCE)),
				request("11", "textDocument/completion", cursorAtEnd(optional, OPTIONAL_SOURCE)),
			]),
		],
		check: (r: LspReplay) => firstFailure([
			sameRows("b. on Box<string>", ["get|2|() => string", "item|5|string", "put|2|(v: string) => void"], completionRows(r, "n:10")),
			sameRows("c?. on Cfg | null", ["host|5|string", "port|5|int32"], completionRows(r, "n:11")),
		]),
		checkAnyBatching: null,
		checkpoints: null,
		project: null,
	};
}

const CALLS_SOURCE = "function clamp(value: int32, low: int32, high: int32): int32 {\n\treturn value < low ? low : value > high ? high : value;\n}\nconst r = clamp(5, 1, 9);\nconst t = clamp(clamp(1, 2, 3), 4, 5);\n";

function clampSignature(activeParameter: int32): string {
	return "signatures 1, activeSignature 0, activeParameter " + activeParameter
		+ ", label clamp(value: int32, low: int32, high: int32): int32, parameters [value: int32, low: int32, high: int32]";
}

function signatureHelpFollowsTheArgument(): LspScenario {
	const uri = "file:///lspwire/calls.ms";
	return {
		name: "signature help names the signature and the argument under the cursor",
		batching: "any",
		drains: [
			initializeDrain(),
			frames([notification("textDocument/didOpen", openParams(uri, CALLS_SOURCE))]),
			frames([
				request("10", "textDocument/signatureHelp", positionParams(uri, 3, 16)),
				request("11", "textDocument/signatureHelp", positionParams(uri, 3, 19)),
				request("12", "textDocument/signatureHelp", positionParams(uri, 3, 22)),
				request("13", "textDocument/signatureHelp", positionParams(uri, 4, 28)),
				request("14", "textDocument/signatureHelp", positionParams(uri, 4, 32)),
			]),
		],
		check: (r: LspReplay) => firstFailure([
			sameText("cursor at the 1st argument", clampSignature(0), signatureSummary(r, "n:10")),
			sameText("cursor at the 2nd argument", clampSignature(1), signatureSummary(r, "n:11")),
			sameText("cursor at the 3rd argument", clampSignature(2), signatureSummary(r, "n:12")),
			sameText("3rd argument of the inner call", clampSignature(2), signatureSummary(r, "n:13")),
			sameText("2nd argument of the outer call", clampSignature(1), signatureSummary(r, "n:14")),
		]),
		checkAnyBatching: null,
		checkpoints: null,
		project: null,
	};
}

function hoverShowsDeclarations(): LspScenario {
	const uri = "file:///lspwire/hover.ms";
	const clamp = "```metascript\nfunction clamp(value: int32, low: int32, high: int32): int32\n```";
	return {
		name: "hover answers the exact markdown and range of a function and a const",
		batching: "any",
		drains: [
			initializeDrain(),
			frames([notification("textDocument/didOpen", openParams(uri, CALLS_SOURCE))]),
			frames([
				request("10", "textDocument/hover", positionParams(uri, 3, 11)),
				request("11", "textDocument/hover", positionParams(uri, 3, 6)),
				request("12", "textDocument/hover", positionParams(uri, 0, 10)),
			]),
		],
		check: (r: LspReplay) => firstFailure([
			sameText("hover on the call clamp", clamp + " @ 3:10-3:15", hoverSummary(r, "n:10")),
			sameText("hover on const r", "```metascript\nconst r: int32\n``` @ 3:6-3:7", hoverSummary(r, "n:11")),
			sameText("hover on the declaration clamp", clamp + " @ 0:9-0:14", hoverSummary(r, "n:12")),
		]),
		checkAnyBatching: null,
		checkpoints: { afterDrains: [1], probes: [{ uri, line: 3, character: 11 }, { uri, line: 3, character: 6 }] },
		project: null,
	};
}

const TOKENS_SOURCE = "class Box {\n\tv: int32;\n\tconstructor(v: int32) {\n\t\tthis.v = v;\n\t}\n}\nfunction add(a: int32): int32 {\n\tconst k = 2;\n\treturn a + k;\n}\n";

// Bug: only the class, `this.v`, the function and the const declaration are tokens; the field
// declaration, both parameter declarations and every parameter or const read are missing.
export function semanticTokensGoldenParked(): LspScenario {
	const uri = "file:///lspwire/tokens.ms";
	return {
		name: "semantic tokens classify every declaration and reference of a class, function, parameter and const",
		batching: "any",
		drains: [
			initializeDrain(),
			frames([notification("textDocument/didOpen", openParams(uri, TOKENS_SOURCE))]),
			frames([request("10", "textDocument/semanticTokens/full", `{"textDocument":{"uri":${lspJsonString(uri)}}}`)]),
		],
		check: (r: LspReplay) => sameRows("tokens", [
			"0:6+3 class declaration",
			"1:1+1 property declaration",
			"2:13+1 parameter declaration",
			"3:7+1 property",
			"3:11+1 parameter",
			"6:9+3 function declaration",
			"6:13+1 parameter declaration",
			"7:7+1 variable declaration+readonly",
			"8:8+1 parameter",
			"8:12+1 variable readonly",
		], semanticRows(r, "n:10")),
		checkAnyBatching: null,
		checkpoints: null,
		project: null,
	};
}

function insignificantEditsKeepAnswers(): LspScenario {
	const uri = "file:///lspwire/insignificant.ms";
	const text = BAD_VALUE + "\nexport const w = value;\n";
	const asked = (id: string) => request(id, "textDocument/hover", positionParams(uri, 1, 17));
	const diagnostics = "[0:28-0:29 1 " + lspJsonString(NOT_ASSIGNABLE) + "]";
	const hover = "```metascript\nconst value: int32\n``` @ 1:17-1:22";
	return {
		name: "a whitespace-only and a comment-only edit republish the same diagnostics and keep hover",
		batching: "any",
		drains: [
			initializeDrain(),
			frames([notification("textDocument/didOpen", openParams(uri, text)), asked("10")]),
			frames([notification("textDocument/didChange", changeParams(uri, 2, text + "   \n")), asked("11")]),
			frames([notification("textDocument/didChange", changeParams(uri, 3, text + "// note\n")), asked("12")]),
		],
		check: (r: LspReplay) => firstFailure([
			sameText("diagnostic counts per publish", "[1,1,1]", publishedCounts(r, uri)),
			sameText("publish 0", diagnostics, publishedAt(r, uri, 0)),
			sameText("publish after the whitespace edit", diagnostics, publishedAt(r, uri, 1)),
			sameText("publish after the comment edit", diagnostics, publishedAt(r, uri, 2)),
			sameText("hover before the edits", hover, hoverSummary(r, "n:10")),
			sameText("hover after the whitespace edit", hover, hoverSummary(r, "n:11")),
			sameText("hover after the comment edit", hover, hoverSummary(r, "n:12")),
		]),
		checkAnyBatching: null,
		checkpoints: { afterDrains: [1, 2, 3], probes: [{ uri, line: 1, character: 17 }, { uri, line: 0, character: 13 }] },
		project: null,
	};
}

export function scenarioSlug(name: string): string {
	let out = "";
	for (let i = 0; i < name.byteLength; i++) {
		const b = name.byteAt(i);
		const keep = (b >= 97 && b <= 122) || (b >= 65 && b <= 90) || (b >= 48 && b <= 57);
		if (keep) out += name.byteSlice(i, i + 1);
		else if (!out.endsWith("-")) out += "-";
	}
	return out;
}

export function lspScenarios(): LspScenario[] {
	return [
		openWithErrorThenFix(),
		multibyteContentLength(),
		twoEditsOneDrain(),
		twoEditsTwoDrains(),
		requestBetweenEdits(),
		supersededAndCoalesced(),
		idsComeBackExactly(),
		shutdownWaitsForExit(),
		afterShutdown(),
		exitAfterShutdown(),
		exitWithoutShutdown(),
		closedBeforeExit(),
		bodyCutShort(),
		headerCutShort(),
		cancelledInDrain(),
		positionEditsShiftRanges(),
		dependencyEditsRecheckDependent(),
		cancelledWorkDoesNotPoison(),
		unusedImportWarnsInEditorAndBatch(),
		buildConfigReachesEditor(),
		twoProjectsKeepTheirConfig(),
		sharedDepResolvesPerProject(),
		globalImportMacroExpands(),
		globalImportSharesClassIdentity(),
		globalImportSharesMacroModuleIdentity(),
		globalImportEditReachesItsUsers(),
		globalImportClosureSeesNoGlobals(),
		globalImportsSeenInOrder(),
		genericReadsItsModuleConst(),
		genericFromMacroImporterReadsItsImports(false),
		genericFromMacroImporterReadsItsImports(true),
		modulePassSurvivesProjectSwitch(),
		signatureHelpFollowsTheArgument(),
		hoverShowsDeclarations(),
		insignificantEditsKeepAnswers(),
		memberCompletionKindsParked(),
		scopeCompletionTiersParked(),
		genericAndOptionalCompletionParked(),
		semanticTokensGoldenParked(),
	];
}

export function lspScenarioByName(name: string): Result<LspScenario, string> {
	for (const scenario of lspScenarios()) {
		if (scenario.name == name) return Result.ok(scenario);
	}
	return Result.err("no LSP scenario named " + lspJsonString(name));
}
