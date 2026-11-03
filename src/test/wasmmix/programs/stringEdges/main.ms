// @stdout: ascii 111111
// @stdout: empty true
// @stdout: two-first 111111
// @stdout: two-middle 111111
// @stdout: two-last 111111
// @stdout: four-first 111111
// @stdout: four-middle 111111
// @stdout: four-last 111111
// @stdout: lone-first 111111
// @stdout: lone-middle 111111
// @stdout: lone-last 111111
// @stdout: two-only 111
// @stdout: four-only 111
import { same, size, made } from "./stringEdgesWasm";

const pad = "abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz";
const sizes: int32[] = [16, 17, 24, 25, 48, 49];

function build(bytes: int32, ch: string, width: int32, at: int32): string {
	const rest = bytes - width;
	const left = at == 0 ? 0 : at == 1 ? rest >> 1 : rest;
	return pad.slice(0, left) + ch + pad.slice(0, rest - left);
}

function agrees(s: string, bytes: int32, ch: string, width: int32, at: int32): boolean {
	return same(s) == s && size(s) == s.length && made(bytes, ch, width, at) == s;
}

function row(label: string, ch: string, width: int32, at: int32): void {
	let bits = "";
	for (const bytes of sizes) {
		bits += agrees(build(bytes, ch, width, at), bytes, ch, width, at) ? "1" : "0";
	}
	console.log(`${label} ${bits}`);
}

function only(label: string, ch: string, units: int32[]): void {
	let bits = "";
	for (const n of units) {
		let s = "";
		for (let i = 0; i < n; i += 1) s += ch;
		bits += same(s) == s && size(s) == s.length ? "1" : "0";
	}
	console.log(`${label} ${bits}`);
}

row("ascii", "a", 1, 2);
console.log(`empty ${same("") == "" && size("") == 0}`);
row("two-first", "é", 2, 0);
row("two-middle", "é", 2, 1);
row("two-last", "é", 2, 2);
row("four-first", "\u{1F600}", 4, 0);
row("four-middle", "\u{1F600}", 4, 1);
row("four-last", "\u{1F600}", 4, 2);
row("lone-first", "\uD800", 3, 0);
row("lone-middle", "\uD800", 3, 1);
row("lone-last", "\uD800", 3, 2);
only("two-only", "é", [23, 24, 25]);
only("four-only", "\u{1F600}", [11, 12, 13]);
