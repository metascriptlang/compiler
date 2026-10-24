import { compileToC, compileProjectToC, MapEntry } from "../helpers";

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

test "E2E C: a stored generator is driven through its iterator" {
	const c = emitFor(`
		const it = count(5);
		for (const x of it) {
			console.log(x);
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
`;

function mainC(consumer: string): string {
	const entries: MapEntry[] = [
		{ entryPath: LIB_PATH, entrySource: LIB },
		{ entryPath: MAIN_PATH, entrySource: `import { count, doubled, firsts, total } from "./lib";\n` + consumer },
	];
	const units = compileProjectToC(entries, MAIN_PATH).split("#include <stdint.h>\n");
	for (const unit of units) {
		if (unit.contains("ZmainOms__Init000(void) {")) return unit;
	}
	return "";
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

test "E2E C: a consumer of a stored chain from another module stays a call" {
	const c = mainC(`
		const it = firsts(count(9), 3);
		console.log(total(it));
	`);
	assert c != "";
	assert c.contains("total__");
}

test "E2E C: a stored chain of generators from another module is driven through its iterator" {
	const c = mainC(`
		const it = count(4).doubled((v: int32): int32 => v + 1);
		let s: int32 = 0;
		for (const y of it) {
			s += y;
		}
		console.log(s);
	`);
	assert c != "";
	assert c.contains("dollariter");
}
