// Language tests: advanced patterns — closures, Result chains, match blocks, pipelines

import { exec } from "std/process";
import { readFile, writeFile } from "std/fs";
import { dirname, join } from "std/fs/path";

type NumFn = (n: number) => number;
type MathResult = Result<number, string>;
type FindResult = Result<number, string>;

enum TokenKind { Num, Str, Bool, Null }
enum Status { Ok, Warn, Error }

function makeAdder(base: number): NumFn {
	return (x: number): number => base + x;
}

function compose(f: NumFn, g: NumFn): NumFn {
	return (x: number): number => f(g(x));
}

function mul2(x: number): number { return x * 2; }
function add1(x: number): number { return x + 1; }

function sumArr(arr: number[]): number {
	let total = 0;
	for (const n of arr) { total += n; }
	return total;
}

function concatStrs(arr: string[]): string {
	let result = "";
	for (const s of arr) { result = result + s; }
	return result;
}

function safeDivide(a: number, b: number): MathResult {
	if (b === 0) return Result.err("div by zero");
	return Result.ok(a / b);
}

function chainCalc(a: number, b: number, c: number): MathResult {
	const ab = try safeDivide(a, b);
	const result = try safeDivide(ab, c);
	return Result.ok(result);
}

function findInArray(arr: number[], target: number): FindResult {
	let i = 0;
	while (i < arr.length) {
		if (arr[i] === target) return Result.ok(i);
		i += 1;
	}
	return Result.err("not found");
}

function tokenLabel(k: TokenKind): string {
	return match (k) {
		TokenKind.Num => { const p = "number"; return p + "_literal"; },
		TokenKind.Str => { const p = "string"; return p + "_literal"; },
		TokenKind.Bool => "bool_literal",
		TokenKind.Null => "null_literal",
	};
}

interface Item { name: string; price: number; qty: number; }
interface Order { items: Item[]; discount: number; }

function orderTotal(order: Order): number {
	let total = 0;
	let i = 0;
	while (i < order.items.length) {
		total += order.items[i].price * order.items[i].qty;
		i += 1;
	}
	if (order.discount > 0) total = total - order.discount;
	return total;
}

function itemCount(order: Order): number {
	let cnt = 0;
	let i = 0;
	while (i < order.items.length) { cnt += order.items[i].qty; i += 1; }
	return cnt;
}

function classifyScore(score: number): Status {
	if (score >= 80) return Status.Ok;
	if (score >= 50) return Status.Warn;
	return Status.Error;
}

function statusMsg(s: Status): string {
	return match (s) {
		Status.Ok => "good",
		Status.Warn => "warning",
		Status.Error => "error",
	};
}

interface DictEntry { key: string; value: string; }
interface Dict { entries: DictEntry[]; }

function dictSet(d: Dict, key: string, value: string): void {
	let i = 0;
	while (i < d.entries.length) {
		if (d.entries[i].key === key) { d.entries[i].value = value; return; }
		i += 1;
	}
	d.entries.push({ key: key, value: value });
}

function dictGet(d: Dict, key: string): string {
	let i = 0;
	while (i < d.entries.length) {
		if (d.entries[i].key === key) return d.entries[i].value;
		i += 1;
	}
	return "";
}

function dictHas(d: Dict, key: string): boolean {
	let i = 0;
	while (i < d.entries.length) {
		if (d.entries[i].key === key) return true;
		i += 1;
	}
	return false;
}

test "closures" {
	const add5 = makeAdder(5);
	const add10 = makeAdder(10);
	assert add5(3) === 8;
	assert add10(3) === 13;
}

test "nested closures (compose)" {
	const mul2add1 = compose(mul2, add1);
	assert mul2add1(3) === 8;
	assert mul2add1(0) === 2;
}

test "for..of" {
	assert sumArr([1, 2, 3, 4, 5]) === 15;
	assert sumArr([]) === 0;
	assert concatStrs(["a", "b", "c"]) === "abc";
}

test "Result chain" {
	const c1 = chainCalc(100, 2, 5);
	assert c1.ok;
	assert c1.value === 10;

	const c2 = chainCalc(100, 0, 5);
	assert !c2.ok;
	assert c2.error === "div by zero";

	const c3 = chainCalc(100, 2, 0);
	assert !c3.ok;
}

test "Result in loop" {
	const f1 = findInArray([10, 20, 30, 40], 30);
	assert f1.ok;
	assert f1.value === 2;

	const f2 = findInArray([10, 20, 30], 99);
	assert !f2.ok;
}

test "match block arms" {
	assert tokenLabel(TokenKind.Num) === "number_literal";
	assert tokenLabel(TokenKind.Str) === "string_literal";
	assert tokenLabel(TokenKind.Bool) === "bool_literal";
}

test "interface pipeline (order)" {
	const order: Order = { items: [], discount: 5 };
	order.items.push({ name: "apple", price: 2, qty: 3 });
	order.items.push({ name: "bread", price: 4, qty: 1 });
	order.items.push({ name: "milk", price: 3, qty: 2 });
	assert orderTotal(order) === 11;
	assert itemCount(order) === 6;
}

function findFirstEven(arr: number[]): number {
	let i = 0;
	while (i < arr.length) {
		if (arr[i] % 2 === 0) return arr[i];
		i += 1;
	}
	return -1;
}

function sumOddsOnly(arr: number[]): number {
	let total = 0;
	let i = 0;
	while (i < arr.length) {
		if (arr[i] % 2 === 0) { i += 1; continue; }
		total += arr[i];
		i += 1;
	}
	return total;
}

test "break and continue" {
	assert findFirstEven([1, 3, 5, 8, 9]) === 8;
	assert findFirstEven([1, 3, 5]) === -1;
	assert sumOddsOnly([1, 2, 3, 4, 5]) === 9;
}

test "path utils" {
	assert dirname("src/parser/core.ms") === "src/parser";
	assert dirname("file.ms") === ".";
	assert join("a", "b") === "a/b";
}

function buildLargeString(lines: number): string {
	let result = "";
	let i = 0;
	while (i < lines) {
		result = result + "line " + i + "\n";
		i += 1;
	}
	return result;
}

test "large file I/O" {
	const content = buildLargeString(100);
	const path = "/tmp/ms_large_test.txt";
	const wr = writeFile(path, content);
	assert wr.ok;
	const rr = readFile(path);
	assert rr.ok;
	const back = rr.value;
	assert back === content;
	assert back.length > 400;
	exec("rm -f " + path);
}

test "enum dispatch" {
	assert statusMsg(classifyScore(90)) === "good";
	assert statusMsg(classifyScore(65)) === "warning";
	assert statusMsg(classifyScore(30)) === "error";
}

test "string key lookup (dict)" {
	const dict: Dict = { entries: [] };
	dictSet(dict, "name", "MetaScript");
	dictSet(dict, "version", "0.1");
	dictSet(dict, "target", "c");

	assert dictGet(dict, "name") === "MetaScript";
	assert dictGet(dict, "version") === "0.1";
	assert dictHas(dict, "target");
	assert !dictHas(dict, "missing");
	assert dictGet(dict, "missing") === "";

	dictSet(dict, "version", "0.2");
	assert dictGet(dict, "version") === "0.2";
	assert dict.entries.length === 3;
}
