import { compileToC } from "../helpers";
import { hostTargetInfo } from "../../checker/types";

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

const CLOSURE_HOLD_SRC = `
function holdsClosure(x: int32): int32 {
	const g = () => x + 1;
	return x + 2;
}
function holdsBare(x: int32): int32 {
	const g = () => 7;
	return x + 2;
}
function useHolds(n: int32): int32 {
	const a = holdsClosure(n);
	const b = holdsBare(a);
	return a + b;
}
console.log(String(useHolds(1)));
`;

test "raiseChecks: a closure value destroyed at scope exit does not make its routine raise" {
	const result = compileToC(CLOSURE_HOLD_SRC);
	assert result.ok, result.error;
	assert checksIn(result.value, "useHolds") == 0;
	assert checksIn(result.value, "holdsClosure") == 0;
	assert checksIn(result.value, "holdsBare") == 0;
}

const IIFE_SRC = `
function plain(x: int32): int32 { return x + 1; }
function boom(x: int32): int32 {
	if (x > 100) throw new Error("big");
	return x + 1;
}
function iifeQuiet(x: int32): int32 { return (() => plain(x))(); }
function iifeBare(): int32 { return (() => plain(3))(); }
function iifeWithArg(x: int32): int32 { return ((y: int32) => plain(y + x))(2); }
function iifeNested(x: int32): int32 { return (() => (() => plain(x))())(); }
function iifeRaises(x: int32): int32 { return (() => boom(x))(); }
function iifeThrows(x: int32): int32 {
	return (() => { if (x > 100) throw new Error("big"); return x; })();
}
function iifeNestedRaises(x: int32): int32 { return (() => (() => boom(x))())(); }
function useQuiet(n: int32): int32 {
	const a = iifeQuiet(n);
	const b = iifeBare();
	const c = iifeWithArg(a);
	const d = iifeNested(c);
	return a + b + c + d;
}
function useRaises(n: int32): int32 {
	const a = iifeRaises(n);
	return a + 1;
}
function useThrows(n: int32): int32 {
	const a = iifeThrows(n);
	return a + 1;
}
function useNestedRaises(n: int32): int32 {
	const a = iifeNestedRaises(n);
	return a + 1;
}
console.log(String(useQuiet(1) + useRaises(2) + useThrows(3) + useNestedRaises(4)));
`;

test "raiseChecks: a closure called where it is written takes its routine's verdict" {
	const result = compileToC(IIFE_SRC);
	assert result.ok, result.error;
	assert checksIn(result.value, "useQuiet") == 0;
	assert checksIn(result.value, "iifeQuiet") == 0;
	assert checksIn(result.value, "iifeNested") == 0;
}

test "raiseChecks: a closure called where it is written keeps the check when its body raises, nested or not" {
	const result = compileToC(IIFE_SRC);
	assert result.ok, result.error;
	assert checksIn(result.value, "useRaises") == 1;
	assert checksIn(result.value, "useThrows") == 1;
	assert checksIn(result.value, "useNestedRaises") == 1;
}

const MANUAL_IIFE_SRC = `
function plain(x: int32): int32 { return x + 1; }
function boom(x: int32): int32 {
	if (x > 100) throw new Error("big");
	return x + 1;
}
function bareQuiet(): int32 { return (() => plain(2))(); }
function bareRaises(n: int32): int32 { return (() => boom(n))(); }
function tryQuiet(): Result<int32, string> {
	const v = try (() => {
		const r: Result<int32, string> = Result.ok(plain(1));
		return r;
	})();
	return Result.ok(v + 1);
}
function useBareQuiet(): int32 {
	const a = bareQuiet();
	return a + 1;
}
function useBareRaises(n: int32): int32 {
	const a = bareRaises(n);
	return a + 1;
}
function useTryQuiet(): int32 {
	const a = tryQuiet();
	return a.ok ? 1 : 0;
}
console.log(String(useBareQuiet() + useBareRaises(1) + useTryQuiet()));
`;

test "raiseChecks: under manual memory a closure called where it is written takes its routine's verdict" {
	const result = compileToC(MANUAL_IIFE_SRC, hostTargetInfo(), true);
	assert result.ok, result.error;
	assert result.value.indexOf("env = NULL }.env") >= 0;
	assert checksIn(result.value, "bareQuiet") == 0;
	assert checksIn(result.value, "tryQuiet") == 0;
	assert checksIn(result.value, "useBareQuiet") == 0;
	assert checksIn(result.value, "useTryQuiet") == 0;
}

test "raiseChecks: under manual memory a closure called where it is written keeps the check when its body raises" {
	const result = compileToC(MANUAL_IIFE_SRC, hostTargetInfo(), true);
	assert result.ok, result.error;
	assert checksIn(result.value, "useBareRaises") == 1;
}
