import { readDir } from "std/fs";
import { join } from "std/fs/path";
import { hashFarm } from "std/core/struct";

const HEX_DIGITS = "0123456789abcdef";

// 64-bit hashFarm over the bytes, run in C, plus the byte length → "hex16_length".
export function hashContent(s: string): string {
	const h = hashFarm(s);
	let hex = "";
	for (let shift: int64 = 60; shift >= 0; shift -= 4) hex += HEX_DIGITS.charAt(((h >> shift) & 15) as int32);
	return `${hex}_${s.byteLength}`;
}

// readDir order is filesystem-dependent; the stamp must be stable across runs.
export function collectFilesSorted(dir: string, prefix: string, outPaths: string[]): void {
	const entries = readDir(dir);
	entries.sort();
	for (const e of entries) {
		if (e.length == 0) continue;
		if (e.charAt(e.length - 1) == "/") {
			const name = e.slice(0, e.length - 1);
			collectFilesSorted(join(dir, name), `${prefix}${name}/`, outPaths);
		} else {
			outPaths.push(`${prefix}${e}`);
		}
	}
}
