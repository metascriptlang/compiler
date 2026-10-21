import { checkOnly } from "../helpers";

const SRC_PARAMS = `
interface ParamList {
	Home: null;
	Detail: { id: string; tab: string | null };
}
type Args<K extends keyof ParamList> = null extends ParamList[K]
	? [name: K, params?: ParamList[K]]
	: [name: K, params: ParamList[K]];
function go<K extends keyof ParamList>(...args: Args<K>): string { return args[0]; }
`;

const SRC_VALID = SRC_PARAMS + `
const a = go("Home");
const b = go("Detail", { id: "a", tab: null });
`;

const SRC_MISSING_PARAMS = SRC_PARAMS + `
const c = go("Detail");
`;

const SRC_TYPO = SRC_PARAMS + `
const d = go("Typo");
`;

const SRC_PLAIN = `
function opt(...args: [name: string, n?: int32]): string { return args[0]; }
const e = opt();
const f = opt("a", 1, 2);
`;

const SRC_LITERAL = `
const t: [string, int32] = ["a"];
const u: [string] = ["a", "b"];
const v: [string, int32?] = ["a"];
`;

const SRC_ORDER = `
const w: [a?: string, b: int32] = [null, 1];
`;

test "a route whose params are optional takes one argument, the others two" {
	const errors = checkOnly(SRC_VALID).errors;
	assert errors.length == 0, "both calls must check: " + errors.join("\n");
}

test "a route whose params are required refuses a call without them" {
	const text = checkOnly(SRC_MISSING_PARAMS).errors.join("\n");
	assert text.contains("Too few arguments: expected at least 2, got 1"), "go(\"Detail\") must be refused: " + text;
}

test "a route name outside the parameter list is refused by the constraint" {
	const text = checkOnly(SRC_TYPO).errors.join("\n");
	assert text.contains("does not satisfy constraint"), "go(\"Typo\") must be refused: " + text;
}

test "a tuple rest parameter bounds the argument count" {
	const text = checkOnly(SRC_PLAIN).errors.join("\n");
	assert text.contains("Too few arguments: expected at least 1, got 0"), "opt() must be refused: " + text;
	assert text.contains("Too many arguments: expected at most 2, got 3"), "opt(a, 1, 2) must be refused: " + text;
}

test "a tuple literal has the tuple's length" {
	const text = checkOnly(SRC_LITERAL).errors.join("\n");
	assert text.contains("Source has 1 element(s) but target '[string, int32]' requires 2"), "a short literal must be refused: " + text;
	assert text.contains("Source has 2 element(s) but target '[string]' allows only 1"), "a long literal must be refused: " + text;
	assert !text.contains("[string, int32 | null?]"), "an omitted optional element must check: " + text;
}

test "a required tuple element cannot follow an optional one" {
	const text = checkOnly(SRC_ORDER).errors.join("\n");
	assert text.contains("A required element cannot follow an optional element"), "the order must be refused: " + text;
}

const SRC_EMPTY = `
function none(...args: []): int32 { return 0; }
type Picked<T> = T extends string ? [] : [T];
function some<T>(...args: Picked<T>): int32 { return 0; }
`;

test "the empty tuple is refused where it is written" {
	const text = checkOnly(SRC_EMPTY).errors.join("\n");
	assert text.contains("the empty tuple type '[]' has no value representation"), "'[]' must be refused: " + text;
}

const SRC_METHOD = SRC_PARAMS + `
class Nav {
	navigate<K extends keyof ParamList>(...args: Args<K>): string { return args[0]; }
}
class Typed<PL> {
	navigate<K extends keyof PL>(...args: null extends PL[K] ? [name: K, params?: PL[K]] : [name: K, params: PL[K]]): string { return args[0] as string; }
}
const nav = new Nav();
const typed = new Typed<ParamList>();
`;

test "a method infers its type parameter from the selected rest tuple as a function does" {
	const errors = checkOnly(SRC_METHOD + `
const a = nav.navigate("Home");
const b = nav.navigate("Detail", { id: "a", tab: null });
const c = typed.navigate("Home");
const d = typed.navigate("Detail", { id: "a", tab: null });
`).errors;
	assert errors.length == 0, "the method calls must check: " + errors.join("\n");
}

test "a method refuses a missing argument and a name outside the list as a function does" {
	const text = checkOnly(SRC_METHOD + `
const c = nav.navigate("Detail");
const d = typed.navigate("Typo");
`).errors.join("\n");
	assert text.contains("Too few arguments: expected at least 2, got 1"), "nav.navigate(\"Detail\") must be refused: " + text;
	assert text.contains("does not satisfy constraint"), "typed.navigate(\"Typo\") must be refused: " + text;
}

test "an excess property is refused through the selected rest tuple as through a written one" {
	const text = checkOnly(SRC_METHOD + `
function direct(...args: [name: "Detail", params: ParamList["Detail"]]): string { return args[0]; }
const e = direct("Detail", { id: "a", tab: null, written: 1 });
const f = go("Detail", { id: "a", tab: null, selected: 1 });
const g = nav.navigate("Detail", { id: "a", tab: null, method: 1 });
`).errors.join("\n");
	assert text.contains("'written' does not exist in type"), "the written tuple must refuse the excess property: " + text;
	assert text.contains("'selected' does not exist in type"), "the selected tuple must refuse the excess property: " + text;
	assert text.contains("'method' does not exist in type"), "the method's selected tuple must refuse the excess property: " + text;
}
