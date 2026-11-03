import { compileToC, compileProjectToC, MapEntry } from "../helpers";
import { execFileResult, cwd, env } from "std/process";
import { writeFile, ensureDir, removeAll, readFile, readDir } from "std/fs";

const generators = `
	function* count(n: int32): Iterator<int32> {
		for (let i: int32 = 0; i < n; i++) {
			yield i;
		}
	}
	function* tail(this xs: string[], from: int32): Iterator<string> {
		for (let i: int32 = from; i < xs.length; i++) {
			yield xs[i];
		}
	}
`;

function emitFor(consumer: string): string {
	const c = compileToC(generators + consumer);
	return c.ok ? c.value : "";
}

test "E2E C: a for-of over a call to a generator drives no iterator" {
	const c = emitFor(`
		let sum: int32 = 0;
		for (const x of count(5)) {
			if (x == 3) break;
			sum += x;
		}
		console.log(sum);
	`);
	assert c != "";
	assert !c.contains("dollariter");
}

test "E2E C: a for-of over an extension generator on an array drives no iterator" {
	const c = emitFor(`
		const words: string[] = ["a", "b", "c"];
		let joined: string = "";
		for (const w of words.tail(1)) {
			joined = joined + w;
		}
		console.log(joined);
	`);
	assert c != "";
	assert !c.contains("dollariter");
}

test "E2E C: a generator stored in a const that one for-of reads drives no iterator" {
	const c = emitFor(`
		const it = count(5);
		for (const x of it) {
			console.log(x);
		}
	`);
	assert c != "";
	assert !c.contains("dollariter");
}

test "E2E C: a stored generator read twice is driven through its iterator" {
	const c = emitFor(`
		const it = count(5);
		for (const x of it) {
			console.log(x);
		}
		for (const y of it) {
			console.log(y);
		}
	`);
	assert c != "";
	assert c.contains("dollariter");
}

const LIB_PATH = "test/generatorInlineInPlace/lib.ms";
const MAIN_PATH = "test/generatorInlineInPlace/main.ms";

const LIB = `export function* count(n: int32): Iterator<int32> {
	for (let i: int32 = 0; i < n; i++) {
		yield i;
	}
}

export function* doubled<T>(this it: Iterator<T>, f: (x: T) => T): Iterator<T> {
	for (const x of it) {
		yield f(f(x));
	}
}

function shut(it: Iterator<int32>): void {
	if (it.return != null) it.return();
}

function* firstN(it: Iterator<int32>, n: int32): Iterator<int32> {
	let left = n;
	for (const x of it) {
		if (left < 1) return;
		left -= 1;
		yield x;
	}
}

export function firsts(it: Iterator<int32>, n: int32): Iterator<int32> {
	if (n < 0) {
		shut(it);
		throw new Error("negative");
	}
	return firstN(it, n);
}

export function total(it: Iterator<int32>): int32 {
	let t: int32 = 0;
	for (const x of it) t += x;
	return t;
}

export function collect(it: Iterator<int32>): int32[] {
	const out: int32[] = [];
	for (const x of it) out.push(x);
	return out;
}

export struct Steps { }

function* stepsLazy(start: int32, end: int32): Iterator<int32> {
	for (let i: int32 = start; i < end; i++) {
		yield i;
	}
}

export function upTo(this typeof Steps, start: int32, end: int32): Iterator<int32> {
	if (end < start) throw new RangeError("backwards");
	return stepsLazy(start, end);
}
`;

function mainC(consumer: string): string {
	const entries: MapEntry[] = [
		{ entryPath: LIB_PATH, entrySource: LIB },
		{ entryPath: MAIN_PATH, entrySource: `import { count, doubled, firsts, total, collect, Steps, upTo } from "./lib";\n` + consumer },
	];
	const units = compileProjectToC(entries, MAIN_PATH).split("#include <stdint.h>\n");
	for (const unit of units) {
		if (unit.contains("ZmainOms__Init000(void) {")) return unit;
	}
	return "";
}

test "E2E C: a consumer under a cast in a compound assignment drives no iterator" {
	const c = mainC(`
		let s: int64 = 0;
		s += (total(count(5))) as int64;
		console.log(s);
	`);
	assert c != "";
	assert !c.contains("dollariter");
	assert !c.contains("total__");
}

test "E2E C: a consumer under a cast in a declaration, an assignment and a return drives no iterator" {
	const c = mainC(`
		function viaReturn(): int64 { return total(count(4)) as int64; }
		const a = total(count(5)) as int64;
		let b: int32 = 0;
		b = total(count(6)) as int32;
		console.log(a, b, viaReturn());
	`);
	assert c != "";
	assert !c.contains("dollariter");
	assert !c.contains("total__");
}

test "E2E C: a field read of a consumer's result drives no iterator" {
	const c = mainC(`
		const n = (collect(count(5))).length;
		console.log(n);
	`);
	assert c != "";
	assert !c.contains("dollariter");
	assert !c.contains("collect__");
}

test "E2E C: a for-of over a static extension from another module drives no iterator" {
	const c = mainC(`
		let s: int32 = 0;
		for (const x of Steps.upTo(0, 10)) {
			if (x == 8) break;
			s += x;
		}
		console.log(s);
	`);
	assert c != "";
	assert !c.contains("dollariter");
	assert !c.contains("upTo__");
}

test "E2E C: a static extension from another module feeding a chain and a consumer drives no iterator" {
	const c = mainC(`
		const s = total(Steps.upTo(0, 9).doubled((v: int32): int32 => v + 1));
		console.log(s);
	`);
	assert c != "";
	assert !c.contains("dollariter");
	assert !c.contains("upTo__");
	assert !c.contains("total__");
}

test "E2E C: a chain of generators from another module consumed by for-of drives no iterator" {
	const c = mainC(`
		let s: int32 = 0;
		for (const y of count(4).doubled((v: int32): int32 => v + 1)) {
			s += y;
		}
		console.log(s);
	`);
	assert c != "";
	assert !c.contains("dollariter");
}

test "E2E C: a consumer of a forwarded chain from another module drives no iterator" {
	const c = mainC(`
		const s = total(firsts(count(9), 3).doubled((v: int32): int32 => v + 1));
		console.log(s);
	`);
	assert c != "";
	assert !c.contains("dollariter");
	assert !c.contains("total__");
}

function maxLineDirective(c: string): int32 {
	let most: int32 = 0;
	for (const part of c.split("#line ").slice(1)) {
		const n = parseInt(part.split(" ")[0]);
		if (n > most) most = n as int32;
	}
	return most;
}

test "E2E C: code inlined from another module is attributed to the line that called it" {
	const c = mainC(`
		const s = total(firsts(count(9), 3).doubled((v: int32): int32 => v + 1));
		console.log(s);
	`);
	assert c != "";
	assert maxLineDirective(c) <= 4;
}

test "E2E C: a consumer of a stored chain inside a larger expression from another module stays a call" {
	const c = mainC(`
		const it = firsts(count(9), 3);
		console.log(total(it));
	`);
	assert c != "";
	assert c.contains("total__");
}

test "E2E C: a chain of generators from another module stored in a const and read once drives no iterator" {
	const c = mainC(`
		const it = count(4).doubled((v: int32): int32 => v + 1);
		let s: int32 = 0;
		for (const y of it) {
			s += y;
		}
		const fw = firsts(count(9), 3);
		const t = total(fw);
		console.log(s + t);
	`);
	assert c != "";
	assert !c.contains("dollariter");
	assert !c.contains("total__");
}

test "E2E C: a stored chain of generators from another module read inside a loop is driven through its iterator" {
	const c = mainC(`
		const it = count(4).doubled((v: int32): int32 => v + 1);
		let s: int32 = 0;
		for (let k: int32 = 0; k < 2; k++) {
			for (const y of it) {
				s += y;
			}
		}
		console.log(s);
	`);
	assert c != "";
	assert c.contains("dollariter");
}

function mainUnitC(name: string, source: string): string {
	const root = cwd();
	const mscEnv = env.get("MSC");
	const msc = mscEnv != "" ? mscEnv : `${root}/msc`;
	const dir = `${root}/out/generatorInlineInPlace/${name}`;
	removeAll(dir);
	ensureDir(dir);
	writeFile(`${dir}/${name}.ms`, source);
	const r = execFileResult(msc, ["build", `${dir}/${name}.ms`, "--emit=c", "--output=prog"], dir);
	if (r.exitCode != 0) return "";
	for (const file of readDir(`${dir}/out/debug`)) {
		if (file == `${name}Oms.c` || file.endsWith(`Z${name}Oms.c`)) {
			const text = readFile(`${dir}/out/debug/${file}`);
			return text.ok ? text.value : "";
		}
	}
	return "";
}

function arrayLoopC(name: string, consumer: string): string {
	return mainUnitC(name, `const xs: int32[] = [1, 2, 3];\nlet s: int64 = 0;\n${consumer}\nconsole.log(s);\n`);
}

function reduceChainC(name: string, consumer: string): string {
	return mainUnitC(name, `function* count(n: int32): Iterator<int32> {\n\tfor (let i: int32 = 0; i < n; i++) yield i;\n}\nconst xs: int32[] = [1, 2, 3, 4];\nconst r = ${consumer};\nconsole.log(r);\n`);
}

function stepsAtLengthWidth(c: string): boolean {
	return c.contains("_ < ((int64_t)") && !c.contains("_ < (*__arr_") && !c.contains("_ < dollarspan_");
}

test "E2E C: a for-of over values() of an array steps an index as wide as the array length" {
	const c = arrayLoopC("widthvalues", `for (const x of xs.values()) s += x as int64;`);
	assert c != "";
	assert stepsAtLengthWidth(c);
}

test "E2E C: a helper chain over keys() or entries() of an array steps an index as wide as the array length" {
	const keys = arrayLoopC("widthkeys", `for (const k of xs.keys().map((k) => k * 2)) s += k as int64;`);
	assert keys != "";
	assert stepsAtLengthWidth(keys);
	const entries = arrayLoopC("widthentries", `for (const e of xs.entries()) s += (e[1] as int64) * (e[0] as int64);`);
	assert entries != "";
	assert stepsAtLengthWidth(entries);
}

test "E2E C: reduce without an initial value after map over a generator runs in the caller's loop" {
	const c = reduceChainC("reducemap", "count(10).map((v: int32, i: number): int32 => v * 2).reduce((a: int32, v: int32, i: number): int32 => a + v)");
	assert c != "";
	assert !c.contains("Iterator_reduce");
	assert !c.contains(".next.fn");
}

test "E2E C: reduce without an initial value after filter over array values runs in the caller's loop" {
	const c = reduceChainC("reducefilter", "xs.values().filter((v: int32, i: number): boolean => v % 2 == 0).reduce((a: int32, v: int32, i: number): int32 => a + v)");
	assert c != "";
	assert !c.contains("Iterator_reduce");
	assert !c.contains(".next.fn");
}
