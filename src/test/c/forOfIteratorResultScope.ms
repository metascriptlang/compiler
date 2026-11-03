import { compileToC } from "../helpers";

const SOURCE = `
export function drain(it: Iterator<int32>): int32 {
	let s: int32 = 0;
	for (const x of it) s += x;
	return s;
}
export function skipOdd(it: Iterator<int32>): int32 {
	let s: int32 = 0;
	for (const x of it) {
		if (x % 2 == 1) continue;
		s += x;
	}
	return s;
}
export function pairs(it: Iterator<int32[]>, kept: int32[][]): void {
	for (const p of it) kept.push(p);
}
function* count(n: int32): Iterator<int32> { for (let i: int32 = 0; i < n; i++) yield i; }
console.log(drain(count(4)), skipOdd(count(4)));
`;

function functionBody(code: string, name: string): string {
	for (const line of code.split("\n")) {
		const at = line.indexOf(" " + name);
		if (at < 0 || !line.endsWith(" {") || line.indexOf("(", at) < 0) continue;
		const start = code.indexOf(line + "\n");
		const end = code.indexOf("\n}", start);
		if (end >= 0) return code.slice(start, end);
	}
	return "";
}

function nextCalls(name: string): int32 {
	const result = compileToC(SOURCE);
	if (!result.ok) return -1;
	const body = functionBody(result.value, name);
	if (body == "") return -1;
	return (body.split("next.env ? ").length - 1) as int32;
}

test "a for-of over a closure iterator asks for the next result at one place" {
	assert nextCalls("drain") == 1;
}

test "a continue in a for-of over a closure iterator reaches the same single call" {
	assert nextCalls("skipOdd") == 1;
}

test "a for-of over a closure iterator of arrays asks for the next result at one place" {
	assert nextCalls("pairs") == 1;
}
