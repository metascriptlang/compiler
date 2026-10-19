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

test "an async lambda does not pass into a parameter returning a plain value" {
	const TAKER = "function takeR(f: (x: number) => number): number { return f(1); }\n";
	assert hasError(TAKER + "takeR(async (x) => 1);", "Argument type mismatch in 'takeR' arg 0");
	assert hasError(TAKER + "takeR(async (x) => { return x; });", "Argument type mismatch in 'takeR' arg 0");
	assert hasError("const f: (x: number) => string = async (x) => \"s\";", "not assignable");
}

test "an async lambda passes into a promise-returning or void-returning parameter" {
	assert strictErrorCount("function takeP(f: (x: number) => Promise<number>): void {}\ntakeP(async (x) => 1);\ntakeP(async (x) => { return x; });") == 0;
	assert strictErrorCount("function eff(f: () => void): void { f(); }\neff(async () => {});") == 0;
}

test "a function returning a value type does not stand in for one returning unknown" {
	const CALL = "function callIt(read: () => unknown): void { read(); }\n";
	assert hasError(CALL + "function seven(): int32 { return 7; }\ncallIt(seven);", "a function returning int32 cannot stand in for one returning unknown");
	assert hasError(CALL + "function word(): string { return \"w\"; }\ncallIt(word);", "a function returning string cannot stand in for one returning unknown");
	assert hasError(CALL + "function yes(): boolean { return true; }\ncallIt(yes);", "Argument type mismatch in 'callIt' arg 0");
	assert strictErrorCount("function seven(): int32 { return 7; }\nconst f: () => unknown = seven;") >= 1;
}

test "a function returning a class instance stands in for one returning unknown" {
	assert strictErrorCount("class Cell { n: number = 3; }\nfunction make(): Cell { return new Cell(); }\nfunction callIt(read: () => unknown): void { read(); }\ncallIt(make);\nconst f: () => unknown = make;") == 0;
}

const UNKNOWN_CB = "function call(cb: (reason: unknown) => void): void {}\n";
const TAKES_ERROR = "parameter 'e' takes Error, but the expected function passes it unknown";

test "a function taking a class does not stand in for one taking unknown" {
	assert hasError(UNKNOWN_CB + "call((e: Error): void => {});", TAKES_ERROR);
	assert hasError(UNKNOWN_CB + "function onErr(e: Error): void {}\ncall(onErr);", TAKES_ERROR);
	assert hasError("const cb: (reason: unknown) => void = (e: Error): void => {};", TAKES_ERROR);
	assert hasError("class Host { run(cb: (reason: unknown) => void): void {} }\nnew Host().run((e: Error): void => {});", TAKES_ERROR);
	assert hasError("interface Named { name: string; }\n" + UNKNOWN_CB + "call((n: Named): void => {});", "parameter 'n' takes Named");
	assert hasError("function call<T>(v: T, cb: (x: T) => void): void {}\nconst u: unknown = new Error(\"x\");\ncall(u, (e: Error): void => {});", "Argument type mismatch in 'call' arg 1");
}

test "a function taking unknown stands in for one taking a class" {
	assert strictErrorCount("function call(cb: (e: Error) => void): void {}\ncall((reason: unknown): void => {});\ncall((reason: unknown | null): void => {});\nconst cb: (e: Error) => void = (reason: unknown): void => {};") == 0;
	assert strictErrorCount(UNKNOWN_CB + "call((reason: unknown): void => {});\ncall((reason: unknown | null): void => {});\ncall((reason) => {});") == 0;
}

test "a function slot holding unknown does not read as a class" {
	assert hasError("function call(make: () => Error): void {}\ncall((): unknown => new Error(\"x\"));", "Argument type mismatch in 'call' arg 0");
	assert strictErrorCount("interface HasErr { x: Error; }\nclass Holder { x: unknown = new Error(\"x\"); }\nconst h: HasErr = new Holder();") >= 1;
	assert strictErrorCount("const us: unknown[] = [];\nconst es: Error[] = us;") >= 1;
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
