import {
	createTransAmDb, dbSetFileText, dbSetStdPath, getFileId, recordModuleImport,
} from "../../transam/index";
import { resolveRuntimeDir } from "../../../utils/path";
import { lspUriToPath } from "../protocol";
import { handleHover, handleInlayHint } from "./queries";

const URI = "file:///boundary.ms";
const LIB_URI = "file:///lib.ms";

const LIB = [
	"@wasm",
	"export function scale(v: Vec<float32>): float32 { return 0; }",
	"",
].join("\n");

const SOURCE = [
	"import { scale as rescale } from \"./lib\";",
	"@wasm",
	"export function sum(xs: Vec<float32>, label: string): int64 { return 0; }",
	"@wasm",
	"export function fill(xs: Span<int32>): void {}",
	"@wasm",
	"export function step(ref n: int32, out s: string): void { s = \"\"; }",
	"@wasm",
	"export function twice<T>(x: T): T { return x; }",
	"@wasm",
	"export function inner(v: Vec<float32>): int64 { return sum(v, \"a\"); }",
	"@wasm",
	"export function hello(s: string): int32 { return 1; }",
	"@wasm",
	"export function add(a: int32, b: int32): int32 { return a + b; }",
	"@wasm",
	"export function pick(x: int32): int32 { return x; }",
	"@wasm",
	"export function pick(x: string): int32 { return 1; }",
	"export function plain(x: int32): int32 { return x; }",
	"function helper(v: Vec<float32>): int64 { return sum(v, \"h\"); }",
	"@wasm",
	"export function viaHelper(v: Vec<float32>): int64 { return helper(v); }",
	"function jsCaller(v: Vec<float32>): int64 { return sum(v, \"j\"); }",
	"function lend(s: Span<int32>): void { fill(s); }",
	"const v: Vec<float32> = [];",
	"const total = sum(v, \"a\");",
	"const greeting = hello(\"x\");",
	"const sumOfTwo = add(1, 2);",
	"const unplaced = plain(1);",
	"const byText = pick(\"t\");",
	"const byNumber = pick(1);",
	"const aliased = rescale(v);",
	"",
].join("\n");

function openDb() {
	const db = createTransAmDb(100);
	dbSetStdPath(db, resolveRuntimeDir() + "/std");
	dbSetFileText(db, lspUriToPath(LIB_URI), LIB);
	dbSetFileText(db, lspUriToPath(URI), SOURCE);
	const user = getFileId(db.fileInput, lspUriToPath(URI));
	const lib = getFileId(db.fileInput, lspUriToPath(LIB_URI));
	recordModuleImport(db.moduleDeps, user, lib);
	return db;
}

function lineOf(text: string): int32 {
	const lines = SOURCE.split("\n");
	for (let i = 0; i < lines.length; i += 1) {
		if (lines[i].indexOf(text) >= 0) return i;
	}
	throw new Error(`no source line contains '${text}'`);
}

function hoverOn(lineText: string, name: string): string {
	const line = lineOf(lineText);
	const character = SOURCE.split("\n")[line].indexOf(name) + 1;
	const params = `{"textDocument":{"uri":"${URI}"},"position":`
		+ `{"line":${line},"character":${character}}}`;
	return handleHover("1", params, openDb());
}

function hintsOn(lineText: string): string {
	const line = lineOf(lineText);
	const params = `{"textDocument":{"uri":"${URI}"},"range":`
		+ `{"start":{"line":${line},"character":0},`
		+ `"end":{"line":${line},"character":0}}}`;
	return handleInlayHint("2", params, openDb());
}

test "hover on a placed function says how each parameter and the result cross" {
	const r = hoverOn("function sum(", "sum");
	assert r.indexOf("runs in wasm when the JS build places it") >= 0, r;
	assert r.indexOf("`xs: Vec<float32>`: copied into wasm memory") >= 0, r;
	assert r.indexOf("`label: string`: encoded (WTF-8) into wasm memory") >= 0, r;
	assert r.indexOf("result: by value (BigInt)") >= 0, r;
}

test "hover on a call of a placed function carries the same section" {
	const r = hoverOn("const total = sum", "sum");
	assert r.indexOf("encoded (WTF-8) into wasm memory") >= 0;
}

test "hover on a writable Span parameter says it is lent and written back" {
	const r = hoverOn("function fill(", "fill");
	assert r.indexOf("`xs: Span<int32>`: lent for the call, written back") >= 0;
}

test "hover on a ref or out parameter says it is written back, also when the call throws" {
	const r = hoverOn("function step(", "step");
	const back = "and written back to the caller's variable after the call, also when it throws";
	assert r.indexOf("`n: ref int32`: by value, " + back) >= 0, r;
	assert r.indexOf("`s: out string`: encoded (WTF-8) into wasm memory, " + back) >= 0, r;
}

test "hover on a refused declaration gives the manifest's reason" {
	const r = hoverOn("function twice<T>", "twice");
	assert r.indexOf("cannot cross: 'twice'") >= 0, r;
	assert r.indexOf("it is generic") >= 0, r;
}

test "hover on a function that is not placed has no boundary section" {
	assert hoverOn("function plain(", "plain").indexOf("JS/wasm boundary") < 0;
}

test "a call from JS-side code carries a hint naming its heaviest argument" {
	const r = hintsOn("const total = sum");
	assert r.indexOf("wasm: copy Vec") >= 0, r;
}

test "string call hints its encoding, scalar call the crossing alone" {
	assert hintsOn("const greeting").indexOf("wasm: encode string") >= 0;
	const scalar = hintsOn("const sumOfTwo");
	assert scalar.indexOf("wasm") >= 0 && scalar.indexOf("wasm:") < 0, scalar;
}

test "a call to a function that is not placed has no boundary hint" {
	assert hintsOn("const unplaced").indexOf("wasm") < 0;
}

test "a call inside wasm-placed code does not cross, so it has no hint" {
	assert hintsOn("function inner(").indexOf("wasm") < 0;
}

test "a helper that wasm code calls is wasm too, so its call has no hint" {
	assert hintsOn("function helper(").indexOf("wasm") < 0;
	assert hintsOn("function jsCaller(").indexOf("wasm: copy Vec") >= 0;
}

test "a call to a Span function hints that the Span is lent" {
	const r = hintsOn("function lend(");
	assert r.indexOf("wasm: lend Span") >= 0, r;
}

test "a call to an overload set hints the overload it resolved to" {
	const r = hintsOn("const byText");
	assert r.indexOf("wasm: encode string") >= 0, r;
	const scalar = hintsOn("const byNumber");
	assert scalar.indexOf("wasm") >= 0 && scalar.indexOf("wasm:") < 0, scalar;
}

test "a call through an import alias hints like the exported name" {
	const r = hintsOn("const aliased");
	assert r.indexOf("wasm: copy Vec") >= 0, r;
}

test "the boundary hint carries no kind, so type-hint filters keep it" {
	const r = hintsOn("const total = sum");
	const at = r.indexOf("wasm: copy Vec");
	assert at >= 0, r;
	assert r.slice(0, r.indexOf("}", at)).indexOf("\"kind\"") < 0, r;
}
