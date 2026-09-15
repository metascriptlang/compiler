// Route 15f: Checker — an argument meeting a function-typed parameter is related like any other argument

import { strictErrorCount, hasError } from "./helpers";

const TAKE = "function takeF(f: (x: number) => void): void { f(1); }\nfunction nf(x: number): void {}\n";
const MAYBE = "function takeM(f: ((x: number) => void) | null): void {}\n";

// ===== Rejected: the value is not a function =====

test "a number does not pass into a function parameter" {
	assert hasError(TAKE + "takeF(5);", "Argument type mismatch in 'takeF' arg 0");
}

test "a string does not pass into a function parameter" {
	assert hasError(TAKE + "takeF(\"x\");", "Argument type mismatch in 'takeF' arg 0");
}

test "an un-narrowed nullable function does not pass into a function parameter" {
	assert hasError(TAKE + "function use(h: ((x: number) => void) | null): void { takeF(h); }", "Argument type mismatch in 'takeF' arg 0");
}

test "null does not pass into a function parameter" {
	assert hasError(TAKE + "takeF(null);", "Argument type mismatch in 'takeF' arg 0");
}

test "a function type has no null to return" {
	assert hasError("function pick(): (x: number) => void { return null; }", "Return type mismatch");
}

test "a lambda literal does not pass into a number parameter" {
	assert hasError("function takeN(n: number): void {}\ntakeN(() => 1);", "Argument type mismatch in 'takeN' arg 0");
}

test "a lambda literal with the wrong parameter type does not pass into a function parameter" {
	assert hasError(TAKE + "takeF((s: string): void => {});", "Argument type mismatch in 'takeF' arg 0");
}

test "a lambda literal with the wrong return type does not pass into a function parameter" {
	assert strictErrorCount("function takeR(f: (x: number) => number): number { return f(1); }\ntakeR((x: number): string => \"s\");") >= 1;
}

test "the rule holds through an interface field closure" {
	assert hasError("interface Sink { cb: (f: (x: number) => void) => void; }\nfunction use(s: Sink, h: ((x: number) => void) | null): void { s.cb(h); }", "arg 0");
}

// ===== Accepted: every function-shaped argument keeps passing =====

test "arrow literals pass, annotated or contextually typed" {
	assert strictErrorCount(TAKE + "takeF((x: number): void => {});\ntakeF((x) => {});") == 0;
}

test "a named function and a function value pass" {
	assert strictErrorCount(TAKE + "takeF(nf);\nconst fv = (x: number): void => {};\ntakeF(fv);") == 0;
}

test "a nullable function narrowed by a null check passes" {
	assert strictErrorCount(TAKE + "function use(h: ((x: number) => void) | null): void { if (h !== null) { takeF(h); } }") == 0;
}

test "a nullable function parameter takes null, a function, and a nullable function" {
	assert strictErrorCount(TAKE + MAYBE + "takeM(null);\ntakeM((x: number): void => {});\ntakeM(nf);\nfunction use(h: ((x: number) => void) | null): void { takeM(h); }") == 0;
}

test "a distinct over a function widens into its base parameter" {
	assert strictErrorCount("type Th = distinct (() => number);\nconst t = (() => 7) as Th;\nfunction takeT(f: () => number): number { return f(); }\ntakeT(t);") == 0;
}

test "an explicit cast still reaches a function parameter" {
	assert strictErrorCount(TAKE + "takeF(null as unknown as (x: number) => void);") == 0;
}

test "overload resolution is unchanged" {
	assert strictErrorCount(TAKE + "function k(f: (x: number) => void): string { return \"fn\"; }\nfunction k(s: string, n: number): string { return \"sn\"; }\nk(nf);\nk(\"a\", 1);") == 0;
}

test "a lambda passes into a void-returning parameter, expression-bodied or not" {
	assert strictErrorCount("function eff(f: () => void): void { f(); }\nlet n = 0;\neff(() => 1);\neff(() => { n = n + 1; });") == 0;
}

test "a named function keeps its return type invariant against the parameter" {
	assert hasError("function eff(f: () => void): void { f(); }\nfunction one(): number { return 1; }\neff(one);", "Argument type mismatch in 'eff' arg 0");
}

test "unannotated lambdas into generic formals still infer" {
	assert strictErrorCount("function mapArr<T, U>(xs: T[], f: (x: T) => U): U[] { const out: U[] = []; for (const x of xs) { out.push(f(x)); } return out; }\nconst ys = mapArr([1, 2], (x) => x + 1);\nconst zs = [1, 2].map((x) => x * 2);") == 0;
}

test "a function value with a matching shape and a contextually typed lambda pass together" {
	assert strictErrorCount(TAKE + "function twice(f: (x: number) => void, g: (x: number) => void): void { f(1); g(2); }\ntwice(nf, (x) => {});") == 0;
}

test "a generic function formal is related once, after binding" {
	assert strictErrorCount("function apply<T>(f: (x: T) => void, v: T): void { f(v); }\napply((x: number): void => {}, 1);") == 0;
	assert strictErrorCount("function apply<T>(f: (x: T) => void, v: T): void { f(v); }\napply(5, 1);") == 1;
}
