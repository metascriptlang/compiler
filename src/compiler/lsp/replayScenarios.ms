// LSP replay scenarios as data: each names its drains and checks a transcript,
// so the in-memory driver and a real-process driver run the same cases.

import { lspFormatMessage, lspJsonString } from "./protocol";
import { lspSplitFrames } from "./transport";
import { parseJson } from "std/serialize/json/parser";
import { JsonKind, JsonValue } from "std/serialize/json/types";
import { getDynamicField, at, asInt32 } from "std/serialize/json/accessors";
import { jsonNull } from "std/serialize/json/builder";

export class LspReplay {
	messages: JsonValue[];
	exitCode: int32;
	drainsConsumed: int32;
}

export type LspBatching = "exact" | "any";

export interface LspScenario {
	name: string;
	batching: LspBatching;
	drains: string[][];
	check: (r: LspReplay) => string;
	checkAnyBatching: ((r: LspReplay) => string) | null;
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

function frames(bodies: string[]): string[] {
	const out: string[] = [];
	for (const body of bodies) out.push(lspFormatMessage(body));
	return out;
}

function request(idJson: string, method: string, params: string): string {
	return `{"jsonrpc":"2.0","id":${idJson},"method":${lspJsonString(method)},"params":${params}}`;
}

function notification(method: string, params: string): string {
	return `{"jsonrpc":"2.0","method":${lspJsonString(method)},"params":${params}}`;
}

function initializeDrain(): string[] {
	return frames([request("1", "initialize", "{}"), notification("initialized", "{}")]);
}

function openParams(uri: string, text: string): string {
	return `{"textDocument":{"uri":${lspJsonString(uri)},"languageId":"metascript","version":1,"text":${lspJsonString(text)}}}`;
}

function changeParams(uri: string, version: int32, text: string): string {
	return `{"textDocument":{"uri":${lspJsonString(uri)},"version":${version}},"contentChanges":[{"text":${lspJsonString(text)}}]}`;
}

function positionParams(uri: string, line: int32, character: int32): string {
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
	};
}

function closedBeforeExit(): LspScenario {
	return {
		name: "input closed before exit ends the loop with code 0",
		batching: "any",
		drains: [initializeDrain()],
		check: (r: LspReplay) => sameCount("exit code", 0, r.exitCode),
		checkAnyBatching: null,
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
	};
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
	];
}

export function lspScenarioByName(name: string): Result<LspScenario, string> {
	for (const scenario of lspScenarios()) {
		if (scenario.name == name) return Result.ok(scenario);
	}
	return Result.err("no LSP scenario named " + lspJsonString(name));
}
