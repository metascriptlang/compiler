import { argv } from "std/process";
import { djb2 } from "std/hash";
import { hashString } from "std/core/struct";

// Per-operation string cost in ns/op (minimum of RUNS runs), one row per operation and size
// class. Run alone for the table: `msc run src/bench/compiler/programs/stringOps.ms [rowPrefix...]`;
// `rt:stringOps` in src/bench/compiler/run.ms measures the same binary's instructions.
// Sizes: bytes of ASCII text, `40u` is 40 bytes of two-byte code points.

let sink: int64 = 0;
const RUNS = 7;
const wanted: string[] = argv.slice(1, argv.length);

function chosen(row: string): boolean {
	if (wanted.length == 0) return true;
	for (const w of wanted) if (row.startsWith(w)) return true;
	return false;
}

function bench(op: string, label: string, n: int32, per: int32, body: (n: int32) => int64): void {
	if (!chosen(op + "." + label)) return;
	let best = 1e30;
	for (let r = 0; r < RUNS; r++) {
		const t0 = performance.now();
		sink ^= body(n);
		const dt = (performance.now() - t0) * 1e6;
		best = Math.min(best, dt / (n * per));
	}
	console.log(`${op}\t${label}\t${best.toFixed(2)}`);
}

function mkStr(size: int32, k: int32, uni: boolean): string {
	let s = "";
	if (uni) {
		for (let j = 0; j < size / 2; j++) s += String.fromCharCode(0x430 + ((j * 7 + k * 3) % 26));
	} else {
		for (let j = 0; j < size; j++) s += String.fromCharCode(97 + ((j * 7 + k * 3) % 26));
	}
	return s;
}

function readIt(s: string): int32 {
	return s.length + (s.length > 0 ? s.charCodeAt(s.length >> 1) : 0);
}

function cell(size: int32, uni: boolean): void {
	const label = String(size) + (uni ? "u" : "");
	const pa: string[] = [];
	const pb: string[] = [];
	const pc: string[] = [];
	const pt: string[] = [];
	const dst: string[] = [];
	for (let k = 0; k < 8; k++) {
		pa.push(mkStr(size, k, uni));
		pb.push(mkStr(size, k, uni));
		pc.push((pa[k].charAt(0) == "z" ? "a" : "z") + pa[k].slice(1, pa[k].length));
		pt.push("  " + pa[k] + "  ");
		dst.push("");
	}
	const n: int32 = 8000000 / (1 + (size >> 5));
	bench("copy", label, n, 1, (n: int32): int64 => {
		let acc: int64 = 0;
		for (let i: int32 = 0; i < n; i++) {
			dst[i & 7] = pa[i & 7];
			acc += dst[(i + 3) & 7].length;
		}
		return acc;
	});
	bench("pass", label, n, 1, (n: int32): int64 => {
		let acc: int64 = 0;
		for (let i: int32 = 0; i < n; i++) acc += readIt(pa[i & 7]);
		return acc;
	});
	bench("eqSame", label, n, 1, (n: int32): int64 => {
		let acc: int64 = 0;
		for (let i: int32 = 0; i < n; i++) if (pa[i & 7] == pb[i & 7]) acc += 1;
		return acc;
	});
	bench("ltSame", label, n, 1, (n: int32): int64 => {
		let acc: int64 = 0;
		for (let i: int32 = 0; i < n; i++) if (pa[i & 7] < pb[i & 7]) acc += 1;
		return acc;
	});
	bench("ltDiff", label, n, 1, (n: int32): int64 => {
		let acc: int64 = 0;
		for (let i: int32 = 0; i < n; i++) if (pa[i & 7] < pc[i & 7]) acc += 1;
		return acc;
	});
	bench("djb2", label, n, 1, (n: int32): int64 => {
		let acc: int64 = 0;
		for (let i: int32 = 0; i < n; i++) acc += djb2(pa[i & 7]);
		return acc;
	});
	bench("hashString", label, n, 1, (n: int32): int64 => {
		let acc: int64 = 0;
		for (let i: int32 = 0; i < n; i++) acc ^= hashString(pa[i & 7]);
		return acc;
	});
	bench("concat", label, n, 1, (n: int32): int64 => {
		let acc: int64 = 0;
		for (let i: int32 = 0; i < n; i++) {
			const c = pa[i & 7] + pb[i & 7];
			acc += c.length + c.charCodeAt(c.length - 1);
		}
		return acc;
	});
	const m: int32 = Math.max(1, n / size);
	bench("idxPerUnit", label, m, uni ? size / 2 : size, (n: int32): int64 => {
		let acc: int64 = 0;
		for (let i: int32 = 0; i < n; i++) {
			const s = pa[i & 7];
			for (let j: int32 = 0; j < s.length; j++) acc += s.charCodeAt(j);
		}
		return acc;
	});
	bench("substr", label, n, 1, (n: int32): int64 => {
		let acc: int64 = 0;
		const a: int32 = uni ? size / 8 : size / 4;
		const b: int32 = uni ? (3 * size) / 8 : (3 * size) / 4;
		for (let i: int32 = 0; i < n; i++) {
			const c = pa[i & 7].slice(a, b);
			acc += c.length + c.charCodeAt(0);
		}
		return acc;
	});
	bench("trim", label, n, 1, (n: int32): int64 => {
		let acc: int64 = 0;
		for (let i: int32 = 0; i < n; i++) {
			const c = pt[i & 7].trim();
			acc += c.length + c.charCodeAt(0);
		}
		return acc;
	});
}

function appendChars(count: int32): int64 {
	let s = "";
	for (let j: int32 = 0; j < count; j++) s += String.fromCharCode(97 + (j & 15));
	return s.length;
}

function misc(): void {
	bench("appendChar", "14", 285000, 14, (n: int32): int64 => {
		let acc: int64 = 0;
		for (let i: int32 = 0; i < n; i++) acc += appendChars(14);
		return acc;
	});
	bench("appendChar", "1024", 4000, 1024, (n: int32): int64 => {
		let acc: int64 = 0;
		for (let i: int32 = 0; i < n; i++) acc += appendChars(1024);
		return acc;
	});
}

for (const s of [14, 40, 1024]) cell(s, false);
cell(40, true);
misc();
console.log(`sink\t-\t${sink}`);
