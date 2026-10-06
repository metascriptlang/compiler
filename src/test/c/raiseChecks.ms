import { compileToC } from "../helpers";

function functionBody(code: string, name: string): string {
	for (const line of code.split("\n")) {
		const at = line.indexOf(" " + name + "__");
		if (at < 0 || !line.endsWith(" {") || line.indexOf("(", at) < 0) continue;
		const start = code.indexOf(line + "\n");
		const end = code.indexOf("\n}", start);
		if (end >= 0) return code.slice(start, end);
	}
	return "";
}

function checksIn(code: string, name: string): int32 {
	const body = functionBody(code, name);
	if (body == "") return -1;
	return (body.split("if (msErr) goto").length - 1) as int32;
}

const RAISES_SRC = `
function pure(n: int32): int32 { return n + 1; }
function chain(n: int32): int32 { return pure(n) * 2; }
function useChain(n: int32): int32 {
	const a = chain(n);
	const b = chain(a);
	return a + b;
}
function thrower(n: int32): int32 {
	if (n > 5) throw new Error("big");
	return n;
}
function viaChain(n: int32): int32 {
	const v = thrower(n);
	return v + 1;
}
function outer(n: int32): int32 {
	const v = viaChain(n);
	return v * 3;
}
function caught(n: int32): int32 {
	try { return thrower(n); } catch (e) { return -1; }
}
function useCaught(n: int32): int32 {
	const v = caught(n);
	return v + 2;
}
function recur(n: int32): int32 { return n <= 0 ? 0 : recur(n - 1) + pure(n); }
function useRecur(n: int32): int32 {
	const v = recur(n);
	return v + 1;
}
function ping(n: int32): int32 { return n <= 0 ? 0 : pong(n - 1); }
function pong(n: int32): int32 {
	if (n == 7) throw new Error("seven");
	return ping(n);
}
function usePing(n: int32): int32 {
	const v = ping(n);
	return v + 1;
}
function callback(f: (x: int32) => int32): int32 {
	const r = f(9);
	return r + 1;
}
function binaryValue(n: int32): int32 {
	const y = pure(1) + thrower(n);
	console.log("after");
	return y;
}
console.log(String(useChain(1) + outer(2) + useCaught(3) + useRecur(4) + usePing(2) + callback(pure) + binaryValue(1)));
`;

test "raiseChecks: a call to a routine that cannot raise, through a chain, carries no error-flag check" {
	const result = compileToC(RAISES_SRC);
	assert result.ok, result.error;
	assert checksIn(result.value, "useChain") == 0;
}

test "raiseChecks: a call to a routine that raises, directly or through a chain, keeps its check" {
	const result = compileToC(RAISES_SRC);
	assert result.ok, result.error;
	assert checksIn(result.value, "viaChain") == 1;
	assert checksIn(result.value, "outer") == 1;
}

test "raiseChecks: a raise caught inside a routine keeps the check there and none at its callers" {
	const result = compileToC(RAISES_SRC);
	assert result.ok, result.error;
	assert checksIn(result.value, "caught") >= 1;
	assert checksIn(result.value, "useCaught") == 0;
}

test "raiseChecks: recursion raises only when a routine of its cycle raises" {
	const result = compileToC(RAISES_SRC);
	assert result.ok, result.error;
	assert checksIn(result.value, "useRecur") == 0;
	assert checksIn(result.value, "usePing") == 1;
}

test "raiseChecks: a statement whose value holds a raising call below its top is checked" {
	const result = compileToC(RAISES_SRC);
	assert result.ok, result.error;
	assert checksIn(result.value, "binaryValue") == 1;
}

test "raiseChecks: a call through a routine value keeps its check" {
	const result = compileToC(RAISES_SRC);
	assert result.ok, result.error;
	assert checksIn(result.value, "callback") == 1;
}

const DISPATCH_SRC = `
class Shape { area(): int32 { return 1; } }
class Square extends Shape { area(): int32 { return 4; } }
class Point { x: int32 = 2; twice(): int32 { return this.x * 2; } }
function useShape(s: Shape): int32 {
	const a = s.area();
	return a + 1;
}
function usePoint(p: Point): int32 {
	const t = p.twice();
	return t + 1;
}
console.log(String(useShape(new Square()) + usePoint(new Point())));
`;

test "raiseChecks: a dispatched method keeps its check, a method with no override is a plain call" {
	const result = compileToC(DISPATCH_SRC);
	assert result.ok, result.error;
	assert checksIn(result.value, "useShape") == 1;
	assert checksIn(result.value, "usePoint") == 0;
}
