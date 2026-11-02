import { createTransAmDb, dbSetFileText } from "../../transam/index";
import { lspUriToPath } from "../protocol";
import { handleHover, handleInlayHint } from "./queries";

const URI = "file:///boundary.ms";

const SOURCE = [
	"@wasm",
	"export function sum(xs: Vec<float32>, label: string): int64 { return 0; }",
	"@wasm",
	"export function fill(xs: Span<int32>): void {}",
	"@wasm",
	"export function twice<T>(x: T): T { return x; }",
	"@wasm",
	"export function inner(v: Vec<float32>): int64 { return sum(v, \"a\"); }",
	"@wasm",
	"export function hello(s: string): int32 { return 1; }",
	"@wasm",
	"export function add(a: int32, b: int32): int32 { return a + b; }",
	"export function plain(x: int32): int32 { return x; }",
	"const v: Vec<float32> = [];",
	"const total = sum(v, \"a\");",
	"const greeting = hello(\"x\");",
	"const sumOfTwo = add(1, 2);",
	"const unplaced = plain(1);",
	"",
].join("\n");

function openDb() {
	const db = createTransAmDb(100);
	dbSetFileText(db, lspUriToPath(URI), SOURCE);
	return db;
}

function hoverAt(line: int32, character: int32): string {
	return handleHover("1", `{"textDocument":{"uri":"${URI}"},"position":{"line":${line},"character":${character}}}`, openDb());
}

function hintsIn(firstLine: int32, lastLine: int32): string {
	return handleInlayHint("2", `{"textDocument":{"uri":"${URI}"},"range":{"start":{"line":${firstLine},"character":0},"end":{"line":${lastLine},"character":0}}}`, openDb());
}

test "hover on a placed function says how each parameter and the result cross" {
	const r = hoverAt(1, 17);
	assert r.indexOf("runs in wasm when the JS build places it") >= 0, r;
	assert r.indexOf("`xs: Vec<float32>`: copied into wasm memory") >= 0, r;
	assert r.indexOf("`label: string`: encoded (WTF-8) into wasm memory") >= 0, r;
	assert r.indexOf("result: by value (BigInt)") >= 0, r;
}

test "hover on a call of a placed function carries the same section" {
	assert hoverAt(14, 14).indexOf("encoded (WTF-8) into wasm memory") >= 0;
}

test "hover on a writable Span parameter says it is lent and written back" {
	assert hoverAt(3, 17).indexOf("`xs: Span<int32>`: lent for the call, written back after it") >= 0;
}

test "hover on a declaration the boundary refuses gives the manifest's reason" {
	const r = hoverAt(5, 18);
	assert r.indexOf("cannot cross: 'twice'") >= 0, r;
	assert r.indexOf("it is generic") >= 0, r;
}

test "hover on a function that is not placed has no boundary section" {
	assert hoverAt(12, 18).indexOf("JS/wasm boundary") < 0;
}

test "a call from JS-side code carries a hint naming its heaviest argument" {
	const r = hintsIn(14, 14);
	assert r.indexOf("wasm: copy Vec") >= 0, r;
}

test "a string-only call hints its encoding and a scalar-only call hints the crossing alone" {
	assert hintsIn(15, 15).indexOf("wasm: encode string") >= 0;
	const scalar = hintsIn(16, 16);
	assert scalar.indexOf("wasm") >= 0 && scalar.indexOf("wasm:") < 0, scalar;
}

test "a call to a function that is not placed has no boundary hint" {
	assert hintsIn(17, 17).indexOf("wasm") < 0;
}

test "a call inside wasm-placed code does not cross, so it has no hint" {
	assert hintsIn(7, 7).indexOf("wasm") < 0;
}
