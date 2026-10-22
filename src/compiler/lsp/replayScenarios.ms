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
	];
}

export function lspScenarioByName(name: string): Result<LspScenario, string> {
	for (const scenario of lspScenarios()) {
		if (scenario.name == name) return Result.ok(scenario);
	}
	return Result.err("no LSP scenario named " + lspJsonString(name));
}
