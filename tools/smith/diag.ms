import { cwd, env, execFileResult, findOnPath, platform } from "std/process";
import { ensureDir, exists, realpath, writeFile } from "std/fs";
import { djb2, hashToHex } from "std/hash";
import { Features, defaults, format } from "./features";
import { generate } from "./gen";
import { Rng, seeded } from "./rng";

const DIAG_SALT = 0x5DEECE66D1A6 as uint64;
const ERRORS_EXPECTED = 1;

const PLAIN_NAMES: string[] = [
	"alpha", "beta", "gamma", "delta", "omega", "sigma", "kappa", "theta", "lambda", "zeta",
];
const KEYWORD_NAMES: string[] = [
	"type", "of", "get", "set", "from", "as", "declare", "namespace", "module", "keyof", "infer",
	"is", "out", "ref", "match", "when", "test",
];
const UNDEFINED_BARE_NAMES: string[] = [
	"type", "of", "from", "as", "async", "declare", "namespace", "module", "keyof", "infer", "is",
	"out", "ref", "match", "when", "test",
];
const FIXED_NAMES: string[] = [
	"dgSite", "DgSite", "run", "flag", "i", "x", "total", "dgHolder", "DgHolder", "xs", "dgCallee",
	"DgCallee", "dgArrow", "DgKwC", "DgKwS", "console",
];

const SLOT_TYPES: string[] = [
	"int8", "int16", "int32", "int64", "uint8", "uint16", "uint32", "uint64", "float32", "float64",
	"boolean", "string",
];
const CALL_TYPES: string[] = ["int32", "int64", "string", "boolean", "float64", "uint8"];
const RETURN_TYPES: string[] = ["int32", "int64", "uint8", "float64", "boolean", "string"];
const COMPARE_OPS: string[] = ["<", "<=", ">", ">=", "==", "!="];
const COMPOUND_OPS: string[] = ["+=", "-=", "*="];

struct Num {
	name: string;
	bits: int32;
	signed: boolean;
	float: boolean;
}

const NUMS: Num[] = [
	{ name: "int8", bits: 8, signed: true, float: false },
	{ name: "int16", bits: 16, signed: true, float: false },
	{ name: "int32", bits: 32, signed: true, float: false },
	{ name: "int64", bits: 64, signed: true, float: false },
	{ name: "uint8", bits: 8, signed: false, float: false },
	{ name: "uint16", bits: 16, signed: false, float: false },
	{ name: "uint32", bits: 32, signed: false, float: false },
	{ name: "uint64", bits: 64, signed: false, float: false },
	{ name: "float32", bits: 32, signed: true, float: true },
	{ name: "float64", bits: 64, signed: true, float: true },
];

enum Kind {
	DeclMismatch,
	AssignMismatch,
	NarrowDecl,
	NarrowAssign,
	ConstWrite,
	UndefinedName,
	ArgCount,
	ArgType,
	MissingReturn,
	SignCompare,
	ShiftAssign,
	KeywordName,
}

const KINDS: Kind[] = [
	Kind.DeclMismatch,
	Kind.AssignMismatch,
	Kind.NarrowDecl,
	Kind.NarrowAssign,
	Kind.ConstWrite,
	Kind.UndefinedName,
	Kind.ArgCount,
	Kind.ArgType,
	Kind.MissingReturn,
	Kind.SignCompare,
	Kind.ShiftAssign,
	Kind.KeywordName,
];

enum Place {
	Function,
	IfBlock,
	ForBlock,
	Method,
	Top,
	Member,
}

const STATEMENT_PLACES: Place[] = [Place.Function, Place.IfBlock, Place.ForBlock, Place.Method, Place.Top];

function kindName(k: Kind): string {
	return match (k) {
		Kind.DeclMismatch => "decl-mismatch",
		Kind.AssignMismatch => "assign-mismatch",
		Kind.NarrowDecl => "narrow-decl",
		Kind.NarrowAssign => "narrow-assign",
		Kind.ConstWrite => "const-write",
		Kind.UndefinedName => "undefined-name",
		Kind.ArgCount => "arg-count",
		Kind.ArgType => "arg-type",
		Kind.MissingReturn => "missing-return",
		Kind.SignCompare => "sign-compare",
		Kind.ShiftAssign => "shift-assign",
		Kind.KeywordName => "keyword-name",
	};
}

function placeName(p: Place): string {
	return match (p) {
		Place.Function => "function",
		Place.IfBlock => "if",
		Place.ForBlock => "for",
		Place.Method => "method",
		Place.Top => "top",
		Place.Member => "member",
	};
}

struct Site {
	place: Place;
	prelude: string[];
	body: string[];
	outer: int32;
	mutate: int32;
	legalLine: string;
	diag: int32;
	col: int32;
	token: string;
	message: string;
	variant: string;
}

export struct Case {
	seed: uint64;
	kind: string;
	variant: string;
	legal: string;
	mutant: string;
	message: string;
	line: int32;
	col: int32;
	token: string;
}

struct Frame {
	lines: string[];
	rows: int32[];
	depths: int32[];
}

struct Wrong {
	tag: string;
	text: string;
	got: string;
	convert: string;
}

export struct Observed {
	exit: int32;
	count: int32;
	message: string;
	line: int32;
	col: int32;
	text: string;
}

function tabs(n: int32): string {
	let out = "";
	for (let i = 0; i < n; i++) { out += "\t"; }
	return out;
}

function pick(rng: Rng, items: string[]): string { return items[rng.below(items.length)]; }

function pickName(rng: Rng): string {
	return rng.chance(50) ? pick(rng, KEYWORD_NAMES) : pick(rng, PLAIN_NAMES);
}

function distinctFrom(rng: Rng, pool: string[], n: int32): string[] {
	const out: string[] = [];
	while (out.length < n) {
		const name = pick(rng, pool);
		if (out.indexOf(name) < 0) { out.push(name); }
	}
	return out;
}

function distinctNames(rng: Rng, n: int32): string[] {
	const out: string[] = [];
	while (out.length < n) {
		const name = pickName(rng);
		if (out.indexOf(name) < 0) { out.push(name); }
	}
	return out;
}

function numberOf(rng: Rng): int32 { return 1 + rng.below(99); }

function isIntName(t: string): boolean {
	for (const n of NUMS) { if (n.name == t) { return !n.float; } }
	return false;
}

function legalLiteral(rng: Rng, t: string): string {
	if (t == "boolean") { return rng.chance(50) ? "true" : "false"; }
	if (t == "string") { return "\"w" + String(numberOf(rng)) + "\""; }
	return String(numberOf(rng));
}

function wrongLiteral(rng: Rng, t: string, forArg: boolean): Wrong {
	const n = numberOf(rng);
	const forms: string[] = [];
	if (t != "string") { forms.push("string"); }
	if (t != "boolean") { forms.push("boolean"); }
	if (t == "boolean" || t == "string") {
		forms.push("int");
		forms.push("float");
	}
	if (isIntName(t) && !forArg) {
		forms.push("frac");
		forms.push("whole");
	}
	const tag = pick(rng, forms);
	const whole = String(n) + ".0";
	const fraction = String(n) + ".5";
	if (tag == "string") { return { tag: tag, text: "\"s" + String(n) + "\"", got: "string", convert: "" }; }
	if (tag == "boolean") { return { tag: tag, text: rng.chance(50) ? "true" : "false", got: "boolean", convert: "" }; }
	if (tag == "int") { return { tag: tag, text: String(n), got: "int32", convert: "" }; }
	if (tag == "float") { return { tag: tag, text: fraction, got: "float64", convert: "" }; }
	if (tag == "frac") {
		return { tag: tag, text: fraction, got: "float64", convert: "drops the fractional part of " + fraction + " — write an explicit 'as " + t + "'" };
	}
	return {
		tag: tag,
		text: whole,
		got: "float64",
		convert: "takes the float " + whole + ", and a float never becomes an integer implicitly — write " + String(n) + ", or an explicit 'as " + t + "'",
	};
}

function mismatchMessage(w: Wrong, t: string): string {
	if (w.convert != "") { return "implicit float64 → " + t + " conversion " + w.convert; }
	return "Type '" + w.got + "' is not assignable to type '" + t + "'";
}

function convertible(source: Num, target: Num): boolean {
	if (target.float) {
		if (source.float) { return source.bits <= target.bits; }
		return source.bits <= (target.bits == 32 ? 16 : 32);
	}
	if (source.float) { return false; }
	if (source.signed == target.signed) { return source.bits <= target.bits; }
	return !source.signed && source.bits < target.bits;
}

function narrowReason(source: Num, target: Num): string {
	if (target.float) {
		if (source.float) { return "may lose precision (float32 has a 24-bit mantissa)"; }
		return target.bits == 32 ? "may lose integer precision above 2^24" : "may lose integer precision above 2^53";
	}
	if (source.signed == target.signed) { return "narrows"; }
	return source.signed ? "changes signedness" : "may exceed the target's maximum";
}

function narrowMessage(source: Num, target: Num, name: string, value: string, op: string): string {
	if (convertible(source, target)) { return ""; }
	const where = op == "" ? "" : " in '" + op + "'";
	const head = "implicit " + source.name + " → " + target.name + " conversion" + where + " ";
	if (source.float && !target.float) {
		return head + "takes the float " + value + ", and a float never becomes an integer implicitly — write an explicit 'as " + target.name + "'";
	}
	return head + narrowReason(source, target) + " — '" + name + "' is declared " + source.name +
		", so its type decides, not its value " + value + "; write an explicit 'as " + target.name +
		"', or declare '" + name + "' without a type";
}

function valueText(v: int32, n: Num): string { return String(v) + (n.float ? ".0" : ""); }

function newSite(place: Place, variant: string): Site {
	return {
		place: place,
		prelude: [],
		body: [],
		outer: 0,
		mutate: 0,
		legalLine: "",
		diag: 0,
		col: 1,
		token: "",
		message: "",
		variant: variant,
	};
}

function pickPlace(rng: Rng): Place { return STATEMENT_PLACES[rng.below(STATEMENT_PLACES.length)]; }

function declMismatch(rng: Rng): Site {
	const t = pick(rng, SLOT_TYPES);
	const w = wrongLiteral(rng, t, false);
	const head = "const " + pickName(rng) + ": " + t + " = ";
	let s = newSite(pickPlace(rng), t + "<-" + w.tag);
	s.body = [head + w.text + ";"];
	s.legalLine = head + legalLiteral(rng, t) + ";";
	s.col = head.length + 1;
	s.token = w.text;
	s.message = mismatchMessage(w, t);
	return s;
}

function assignMismatch(rng: Rng): Site {
	const t = pick(rng, SLOT_TYPES);
	const w = wrongLiteral(rng, t, false);
	const name = pickName(rng);
	const form = rng.below(3);
	const start = legalLiteral(rng, t);
	let s = newSite(pickPlace(rng), t + "<-" + w.tag + (form == 0 ? "/local" : form == 1 ? "/field" : "/element"));
	let setup = "let " + name + ": " + t + " = " + start + ";";
	let target = name;
	if (form == 1) {
		s.prelude = ["struct DgHolder { " + name + ": " + t + "; }"];
		setup = "let dgHolder: DgHolder = { " + name + ": " + start + " };";
		target = "dgHolder." + name;
	} else if (form == 2) {
		setup = "let xs: " + t + "[] = [" + start + "];";
		target = "xs[0]";
	}
	const head = target + " = ";
	s.body = [setup, head + w.text + ";"];
	s.outer = 1;
	s.mutate = 1;
	s.legalLine = head + legalLiteral(rng, t) + ";";
	s.diag = 1;
	s.col = head.length + 1;
	s.token = w.text;
	s.message = mismatchMessage(w, t);
	return s;
}

function numericPair(rng: Rng): Num[] {
	const a = rng.below(NUMS.length);
	let b = rng.below(NUMS.length - 1);
	if (b >= a) { b++; }
	return [NUMS[a], NUMS[b]];
}

function narrowDecl(rng: Rng): Site {
	const pair = numericPair(rng);
	const names = distinctNames(rng, 2);
	const v = numberOf(rng);
	const head = "const " + names[1] + ": " + pair[1].name + " = ";
	let s = newSite(pickPlace(rng), pair[0].name + ">" + pair[1].name + "/decl");
	s.body = ["const " + names[0] + ": " + pair[0].name + " = " + String(v) + ";", head + names[0] + ";"];
	s.outer = 1;
	s.mutate = 1;
	s.legalLine = head + names[0] + " as " + pair[1].name + ";";
	s.diag = 1;
	s.col = head.length + 1;
	s.token = names[0];
	s.message = narrowMessage(pair[0], pair[1], names[0], valueText(v, pair[0]), "");
	return s;
}

function narrowAssign(rng: Rng): Site {
	const pair = numericPair(rng);
	const names = distinctNames(rng, 2);
	const v = numberOf(rng);
	const bothInt = !pair[0].float && !pair[1].float;
	const op = bothInt && rng.chance(50) ? pick(rng, COMPOUND_OPS) : "=";
	const head = names[1] + " " + op + " ";
	let s = newSite(pickPlace(rng), pair[0].name + ">" + pair[1].name + "/" + (op == "=" ? "assign" : "compound"));
	s.body = [
		"const " + names[0] + ": " + pair[0].name + " = " + String(v) + ";",
		"let " + names[1] + ": " + pair[1].name + " = 1;",
		head + names[0] + ";",
	];
	s.outer = 2;
	s.mutate = 2;
	s.legalLine = head + names[0] + " as " + pair[1].name + ";";
	s.diag = 2;
	s.col = head.length + 1;
	s.token = names[0];
	s.message = narrowMessage(pair[0], pair[1], names[0], valueText(v, pair[0]), op == "=" ? "" : op);
	return s;
}

function constWrite(rng: Rng): Site {
	const forms: string[] = ["=", "+=", "-=", "*=", "++", "--", "pre++", "pre--"];
	const form = pick(rng, forms);
	const t = form == "=" ? pick(rng, ["int8", "int32", "uint64", "float64"]) : pick(rng, ["int16", "int32", "int64", "uint8", "uint32"]);
	const name = pickName(rng);
	const start = " " + name + ": " + t + " = " + String(numberOf(rng)) + ";";
	let s = newSite(pickPlace(rng), t + "/" + form);
	const write = match (form) {
		"=" => name + " = " + String(numberOf(rng)) + ";",
		"++" => name + "++;",
		"--" => name + "--;",
		"pre++" => "++" + name + ";",
		"pre--" => "--" + name + ";",
		_ => name + " " + form + " " + String(numberOf(rng)) + ";",
	};
	s.body = ["const" + start, write];
	s.outer = 1;
	s.mutate = 0;
	s.legalLine = "let" + start;
	s.diag = 1;
	s.col = form.startsWith("pre") ? 3 : 1;
	s.token = name;
	s.message = "cannot assign to '" + name + "' — '" + name + "' is const (use 'let')";
	return s;
}

function undefinedName(rng: Rng): Site {
	const forms: string[] = ["operand", "argument", "condition", "assign-target", "negated", "member-base"];
	const form = pick(rng, forms);
	const t = form == "member-base" ? "int32" : pick(rng, ["int32", "int64", "float64"]);
	const names = distinctNames(rng, 2);
	const name = names[0];
	let missing = name + "Q";
	if (rng.chance(50)) {
		missing = pick(rng, UNDEFINED_BARE_NAMES);
		while (missing == name || missing == names[1]) { missing = pick(rng, UNDEFINED_BARE_NAMES); }
	}
	let s = newSite(pickPlace(rng), t + "/" + form + (missing.endsWith("Q") ? "/misspelt" : "/bare"));
	let head = "";
	let tail = "";
	let defined = name;
	s.body = ["let " + name + ": " + t + " = 1;", ""];
	if (form == "operand") {
		head = name + " = ";
		tail = " + 1;";
	} else if (form == "argument") {
		head = "console.log(";
		tail = ");";
	} else if (form == "condition") {
		head = "if (";
		tail = " > 1) { " + name + " = 2; }";
	} else if (form == "assign-target") {
		tail = " = 3;";
	} else if (form == "negated") {
		head = name + " = -";
		tail = ";";
	} else {
		head = name + " = ";
		tail = ".length;";
		defined = names[1];
		s.body = ["let " + name + ": " + t + " = 1;", "const " + names[1] + ": int32[] = [1];", ""];
	}
	const at = s.body.length - 1;
	s.body[at] = head + missing + tail;
	s.outer = at;
	s.mutate = at;
	s.legalLine = head + defined + tail;
	s.diag = at;
	s.col = head.length + 1;
	s.token = missing;
	s.message = "Undefined variable '" + missing + "'";
	return s;
}

function callPrelude(method: boolean, callee: string, params: string): string[] {
	if (method) { return ["class DgCallee { " + callee + "(" + params + "): void {} }", "const dgCallee = new DgCallee();"]; }
	return ["function " + callee + "(" + params + "): void {}"];
}

function paramList(names: string[], types: string[]): string {
	const parts: string[] = [];
	for (let k = 0; k < types.length; k++) { parts.push(names[k + 1] + ": " + types[k]); }
	return parts.join(", ");
}

function callSite(rng: Rng, kind: Kind): Site {
	const method = rng.chance(50);
	const tooMany = rng.chance(50);
	const count = kind == Kind.ArgCount && tooMany ? rng.below(4) : 1 + rng.below(3);
	const names = distinctNames(rng, 1 + count);
	const callee = names[0];
	const types: string[] = [];
	const args: string[] = [];
	for (let k = 0; k < count; k++) {
		const t = pick(rng, CALL_TYPES);
		types.push(t);
		args.push(legalLiteral(rng, t));
	}
	const prefix = method ? "dgCallee." + callee : callee;
	const quoted = method ? " to '" + callee + "'" : "";
	const label = (method ? "method/" : "function/") + String(count);
	const mutantArgs: string[] = [];
	for (const a of args) { mutantArgs.push(a); }
	let message = "";
	let variant = label;
	if (kind == Kind.ArgCount) {
		variant = label + (tooMany ? "/too-many" : "/too-few");
		if (tooMany) {
			mutantArgs.push(String(numberOf(rng)));
			message = "Too many arguments" + quoted + ": expected at most " + String(count) + ", got " + String(count + 1);
		} else {
			mutantArgs.pop();
			message = "Too few arguments" + quoted + ": expected at least " + String(count) + ", got " + String(count - 1);
		}
	} else {
		const at = rng.below(count);
		const w = wrongLiteral(rng, types[at], true);
		mutantArgs[at] = w.text;
		variant = label + "/" + types[at] + "<-" + w.tag;
		message = "Argument type mismatch in '" + callee + "' arg " + String(at) + ": got " + w.got + ", expected " + types[at];
	}
	let s = newSite(pickPlace(rng), variant);
	s.prelude = callPrelude(method, callee, paramList(names, types));
	s.body = [prefix + "(" + mutantArgs.join(", ") + ");"];
	s.legalLine = prefix + "(" + args.join(", ") + ");";
	s.col = prefix.length + 1;
	s.token = "(";
	s.message = message;
	return s;
}

function missingReturn(rng: Rng): Site {
	const t = pick(rng, RETURN_TYPES);
	const names = distinctNames(rng, 2);
	const name = names[0];
	const shape = rng.below(7);
	const places: Place[] = [Place.Top, Place.Top, Place.Function, Place.IfBlock, Place.ForBlock, Place.Member, Place.Member];
	const labels: string[] = ["function", "arrow", "arrow-in-function", "arrow-in-if", "arrow-in-for", "method", "static-method"];
	const arrow = shape >= 1 && shape <= 4;
	const value = legalLiteral(rng, t);
	let s = newSite(places[shape], labels[shape] + "/" + t);
	let head = "function " + name + "(x: int32): " + t + " {";
	let tail = "}";
	let shown = name;
	s.col = "function ".length + 1;
	s.token = name;
	if (arrow) {
		head = "const " + name + " = (x: int32): " + t + " => {";
		tail = "};";
		shown = "<arrow>";
		s.col = "const ".length + name.length + " = ".length + 1;
		s.token = "(";
	} else if (shape >= 5) {
		head = (shape == 6 ? "static " : "") + name + "(x: int32): " + t + " {";
		s.col = shape == 6 ? "static ".length + 1 : 1;
	}
	s.body = [
		head,
		"\tif (x > " + String(rng.below(9)) + ") {",
		"\t\treturn " + legalLiteral(rng, t) + ";",
		"\t}",
		"\tconst " + names[1] + ": " + t + " = " + value + ";",
		tail,
	];
	s.mutate = 4;
	s.legalLine = "\treturn " + value + ";";
	s.message = "'" + shown + "' lacks an ending return statement: its return type '" + t + "' needs a value on every path";
	return s;
}

function signCompare(rng: Rng): Site {
	const signedType = NUMS[rng.below(4)];
	const unsignedType = NUMS[4 + rng.below(4)];
	const op = pick(rng, COMPARE_OPS);
	const swap = rng.chance(50);
	const names = distinctNames(rng, 3);
	const left = swap ? names[1] : names[0];
	const right = swap ? names[0] : names[1];
	const leftType = swap ? unsignedType : signedType;
	const rightType = swap ? signedType : unsignedType;
	const head = "const " + names[2] + ": boolean = " + left + " ";
	let s = newSite(pickPlace(rng), signedType.name + "~" + unsignedType.name + (swap ? "/swapped/" : "/") + op);
	s.body = [
		"const " + names[0] + ": " + signedType.name + " = " + String(numberOf(rng)) + ";",
		"const " + names[1] + ": " + unsignedType.name + " = " + String(numberOf(rng)) + ";",
		head + op + " " + right + ";",
	];
	s.outer = 2;
	s.mutate = 2;
	s.legalLine = head + op + " (" + right + " as " + leftType.name + ");";
	s.diag = 2;
	s.col = head.length + 1;
	s.token = op;
	if (signedType.bits <= unsignedType.bits) {
		s.message = "operator '" + op + "' cannot compare '" + leftType.name + "' and '" + rightType.name +
			"': neither type holds every value of the other — convert one side with `as`";
	}
	return s;
}

function shiftAssign(rng: Rng): Site {
	const t = NUMS[rng.below(8)];
	const name = pickName(rng);
	const amount = String(1 + rng.below(7));
	let s = newSite(pickPlace(rng), t.name);
	s.body = ["let " + name + ": " + t.name + " = " + String(numberOf(rng)) + ";", name + " >>>= " + amount + ";"];
	s.outer = 1;
	s.mutate = 1;
	s.legalLine = name + " >>= " + amount + ";";
	s.diag = 1;
	s.col = name.length + 2;
	s.token = ">>>=";
	if (t.signed) {
		s.message = "'>>>=' cannot store the 'u" + t.name + "' result of '>>>' in '" + t.name + "'";
	}
	return s;
}

function keywordLines(form: string, names: string[]): string[] {
	const n = names[0];
	if (form == "local") { return ["let " + n + ": int32 = 1; " + n + " = " + n + " + 1; " + n + " += 2;"]; }
	if (form == "for-of") { return ["let total: int32 = 0;", "for (const " + n + " of [1, 2]) { total += " + n + "; }"]; }
	if (form == "arrow-param") { return ["const dgArrow = (" + n + ": int32): int32 => " + n + " + 1;"]; }
	if (form == "function") { return ["function " + n + "(" + names[1] + ": int32): int32 { return " + names[1] + " + 1; }"]; }
	if (form == "class-members") {
		return ["class DgKwC { " + n + ": int32 = 1; " + names[1] + "(" + names[2] + ": int32): int32 { return this." + n + " + " + names[2] + "; } }"];
	}
	return ["struct DgKwS { " + n + ": int32; " + names[1] + ": int32; }"];
}

function keywordName(rng: Rng): Site {
	const forms: string[] = ["local", "for-of", "arrow-param", "function", "class-members", "struct-fields"];
	const form = pick(rng, forms);
	const topOnly = form == "function" || form == "class-members" || form == "struct-fields";
	let s = newSite(topOnly ? Place.Top : pickPlace(rng), form);
	s.body = keywordLines(form, distinctFrom(rng, KEYWORD_NAMES, 3));
	s.mutate = s.body.length - 1;
	s.outer = s.mutate;
	s.legalLine = keywordLines(form, distinctFrom(rng, PLAIN_NAMES, 3))[s.mutate];
	return s;
}

function siteOf(kind: Kind, rng: Rng): Site {
	return match (kind) {
		Kind.DeclMismatch => declMismatch(rng),
		Kind.AssignMismatch => assignMismatch(rng),
		Kind.NarrowDecl => narrowDecl(rng),
		Kind.NarrowAssign => narrowAssign(rng),
		Kind.ConstWrite => constWrite(rng),
		Kind.UndefinedName => undefinedName(rng),
		Kind.ArgCount => callSite(rng, Kind.ArgCount),
		Kind.ArgType => callSite(rng, Kind.ArgType),
		Kind.MissingReturn => missingReturn(rng),
		Kind.SignCompare => signCompare(rng),
		Kind.ShiftAssign => shiftAssign(rng),
		Kind.KeywordName => keywordName(rng),
	};
}

function frame(place: Place, hoist: boolean, prelude: string[], body: string[], outer: int32): Frame {
	const lines: string[] = [];
	const rows: int32[] = [];
	const depths: int32[] = [];
	for (const p of prelude) { lines.push(p); }
	let base = 0;
	let nested = "";
	let tail: string[] = [];
	if (place == Place.Function) {
		lines.push("function dgSite(): void {");
		base = 1;
		tail = ["}"];
	} else if (place == Place.IfBlock) {
		lines.push("function dgSite(flag: boolean): void {");
		base = 1;
		nested = "if (flag) {";
		tail = ["}"];
	} else if (place == Place.ForBlock) {
		lines.push("function dgSite(): void {");
		base = 1;
		nested = "for (let i = 0; i < 2; i++) {";
		tail = ["}"];
	} else if (place == Place.Method) {
		lines.push("class DgSite {");
		lines.push("\trun(): void {");
		base = 2;
		tail = ["\t}", "}"];
	} else if (place == Place.Member) {
		lines.push("class DgSite {");
		base = 1;
		tail = ["}"];
	}
	const before = nested != "" && hoist ? outer : 0;
	for (let i = 0; i < body.length; i++) {
		if (nested != "" && i == before) { lines.push(tabs(base) + nested); }
		const depth = base + (nested != "" && i >= before ? 1 : 0);
		rows.push(lines.length);
		depths.push(depth);
		lines.push(tabs(depth) + body[i]);
	}
	if (nested != "") { lines.push(tabs(base) + "}"); }
	for (const t of tail) { lines.push(t); }
	return { lines: lines, rows: rows, depths: depths };
}

function lineCount(text: string): int32 { return text.split("\n").length - 1; }

function assemble(seed: uint64, base: string, kind: string, s: Site, hoist: boolean): Case {
	const fr = frame(s.place, hoist, s.prelude, s.body, s.outer);
	const banner = "// diag " + kind + " " + s.variant + " place=" + placeName(s.place) + " seed=" + String(seed) + "\n";
	const legalLines: string[] = [];
	for (const l of fr.lines) { legalLines.push(l); }
	legalLines[fr.rows[s.mutate]] = tabs(fr.depths[s.mutate]) + s.legalLine;
	const refused = s.message != "";
	return {
		seed: seed,
		kind: kind,
		variant: s.variant + "/" + placeName(s.place),
		legal: base + banner + legalLines.join("\n") + "\n",
		mutant: base + banner + fr.lines.join("\n") + "\n",
		message: s.message,
		line: refused ? lineCount(base) + 2 + fr.rows[s.diag] : 0,
		col: refused ? fr.depths[s.diag] + s.col : 0,
		token: refused ? s.token : "",
	};
}

export function buildCase(seed: uint64, base: string): Case {
	const rng = Rng.seeded(seed ^ DIAG_SALT);
	const kind = KINDS[(seed % (KINDS.length as uint64)) as int32];
	const s = siteOf(kind, rng);
	return assemble(seed, base, kindName(kind), s, rng.chance(50));
}

export function caseFor(seed: uint64): Case {
	return buildCase(seed, generate(seed, Features.defaults()));
}

function allDigits(text: string): boolean {
	if (text == "" || text.length > 9) { return false; }
	for (let i = 0; i < text.length; i++) {
		const code = text.charCodeAt(i);
		if (code < 48 || code > 57) { return false; }
	}
	return true;
}

function positionOf(arrow: string): int32[] {
	const parts = arrow.trim().split(":");
	if (parts.length < 3) { return [0, 0]; }
	const line = parts[parts.length - 2];
	const col = parts[parts.length - 1];
	if (!allDigits(line) || !allDigits(col)) { return [0, 0]; }
	return [line.parseInt() as int32, col.parseInt() as int32];
}

export function parseCheck(exit: int32, output: string, errorOutput: string): Observed {
	const text = output + errorOutput;
	const lines = text.split("\n");
	let count = 0;
	let message = "";
	let line = 0;
	let col = 0;
	for (let i = 0; i < lines.length; i++) {
		if (!lines[i].startsWith("error: ")) { continue; }
		const rest = lines[i].slice("error: ".length, lines[i].length);
		if (rest.contains(" type error(s) found")) { continue; }
		count++;
		if (count == 1) {
			message = rest;
			if (i + 1 < lines.length && lines[i + 1].trim().startsWith("--> ")) {
				const at = positionOf(lines[i + 1].trim().slice("--> ".length, lines[i + 1].trim().length));
				line = at[0];
				col = at[1];
			}
		}
	}
	return { exit: exit, count: count, message: message, line: line, col: col, text: text };
}

function isClean(o: Observed): boolean { return o.exit == 0 && o.count == 0; }

export function judge(c: Case, legal: Observed, mutant: Observed): string {
	if (!isClean(legal)) { return "false-alarm"; }
	if (c.message == "") { return isClean(mutant) ? "clean" : "false-alarm"; }
	if (isClean(mutant)) { return "missed"; }
	if (mutant.count == 0) { return "crash"; }
	if (mutant.message != c.message) { return "wrong-message"; }
	if (mutant.line != c.line || mutant.col != c.col) { return "wrong-position"; }
	if (mutant.count != ERRORS_EXPECTED) { return "extra-errors"; }
	return "clean";
}

function slashes(p: string): string { return p.replaceAll("\\", "/"); }

function subjectMsc(root: string): string {
	const explicit = env.get("MSC");
	if (explicit != "") { return slashes(realpath(explicit)); }
	const exe = platform == "windows" ? "/msc.exe" : "/msc";
	if (exists(root + exe)) { return root + exe; }
	const installed = findOnPath("msc");
	return installed == "" ? "" : slashes(realpath(installed));
}

function checkFile(msc: string, file: string): Observed {
	const r = execFileResult(msc, ["check", file, "--no-color"]);
	return parseCheck(r.started ? r.exitCode : 127, r.output, r.errorOutput);
}

function describe(o: Observed): string {
	if (o.count == 0) { return o.exit == 0 ? "clean" : "no diagnostic, exit " + String(o.exit) + ": " + o.text.trim().split("\n")[0]; }
	return o.message + " @ " + String(o.line) + ":" + String(o.col) + " (" + String(o.count) + " error(s))";
}

function metaText(c: Case, verdict: string, legal: Observed, mutant: Observed, msc: string, version: string): string {
	return "seed: " + String(c.seed) + "\n" +
		"kind: " + c.kind + "\n" +
		"variant: " + c.variant + "\n" +
		"verdict: " + verdict + "\n" +
		"features: " + Features.defaults().format() + "\n" +
		"expected: " + (c.message == "" ? "clean" : c.message + " @ " + String(c.line) + ":" + String(c.col) + " token '" + c.token + "' (" + String(ERRORS_EXPECTED) + " error(s))") + "\n" +
		"observed-legal: " + describe(legal) + "\n" +
		"observed-mutant: " + describe(mutant) + "\n" +
		"msc: " + msc + "\n" +
		"msc-version: " + version + "\n";
}

function record(bundles: string, c: Case, meta: string, legal: Observed, mutant: Observed): string {
	const dir = bundles + "/" + String(c.seed) + "-" + hashToHex(djb2(meta + "\n" + c.legal + "\n" + c.mutant)).slice(0, 8);
	if (exists(dir)) { return dir + " (already recorded, left untouched)"; }
	ensureDir(dir);
	writeFile(dir + "/legal.ms", c.legal);
	writeFile(dir + "/mutant.ms", c.mutant);
	writeFile(dir + "/meta", meta);
	writeFile(dir + "/legal.out", legal.text);
	writeFile(dir + "/mutant.out", mutant.text);
	return dir;
}

function sweep(first: uint64, count: int32, planted: boolean): int32 {
	const root = slashes(cwd());
	const msc = subjectMsc(root);
	if (msc == "") {
		console.log("diag: no compiler under test: set MSC, build ./msc, or install msc");
		return 2;
	}
	const v = execFileResult(msc, ["--version", "--no-color"]);
	const version = (v.output + v.errorOutput).trim();
	const out = root + "/out/smith/diag";
	ensureDir(out + "/sandbox");
	let clean = 0;
	let findings = 0;
	for (let i = 0; i < count; i++) {
		const seed = first + (i as uint64);
		const built = caseFor(seed);
		const c: Case = planted ? { ...built, col: built.col + 1 } : built;
		writeFile(out + "/sandbox/diag" + String(seed) + ".legal.ms", c.legal);
		writeFile(out + "/sandbox/diag" + String(seed) + ".mutant.ms", c.mutant);
		const legal = checkFile(msc, out + "/sandbox/diag" + String(seed) + ".legal.ms");
		const mutant = checkFile(msc, out + "/sandbox/diag" + String(seed) + ".mutant.ms");
		const verdict = judge(c, legal, mutant);
		if (verdict == "clean") {
			clean++;
			continue;
		}
		findings++;
		const dir = record(out + (planted ? "/plant-bundles" : "/bundles"), c, metaText(c, verdict, legal, mutant, msc, version), legal, mutant);
		console.log("  diag" + String(seed) + " " + c.kind + "/" + c.variant + " " + verdict + " → " + dir);
	}
	console.log(String(count) + " programs · " + String(clean) + " clean · " + String(findings) + " findings");
	return findings > 0 ? 1 : 0;
}

export function runDiag(first: uint64, count: int32): int32 { return sweep(first, count, false); }

export function runPlanted(first: uint64, count: int32): int32 { return sweep(first, count, true); }

const SMALL_BASE = "console.log(1);\n";

function lineAt(text: string, n: int32): string { return text.split("\n")[n - 1]; }

function observed(count: int32, message: string, line: int32, col: int32): Observed {
	return { exit: count == 0 ? 0 : 1, count: count, message: message, line: line, col: col, text: "" };
}

function refusing(message: string, line: int32, col: int32): Case {
	return { seed: 1, kind: "k", variant: "v", legal: "", mutant: "", message: message, line: line, col: col, token: "t" };
}

test "a mutant differs from its legal twin by exactly one line" {
	for (let seed = 1; seed <= 240; seed++) {
		const c = buildCase(seed as uint64, SMALL_BASE);
		const legal = c.legal.split("\n");
		const mutant = c.mutant.split("\n");
		assert legal.length == mutant.length;
		let differing = 0;
		for (let i = 0; i < legal.length; i++) { if (legal[i] != mutant[i]) { differing++; } }
		assert differing == 1;
	}
}

test "the expected line and column point at the token in the mutant, whatever surrounds it" {
	for (let seed = 1; seed <= 240; seed++) {
		const c = buildCase(seed as uint64, SMALL_BASE);
		if (c.message == "") { continue; }
		assert lineAt(c.mutant, c.line).slice(c.col - 1, c.col - 1 + c.token.length) == c.token;
	}
	for (let seed = 1; seed <= 24; seed++) {
		const c = caseFor(seed as uint64);
		if (c.message == "") { continue; }
		assert lineAt(c.mutant, c.line).slice(c.col - 1, c.col - 1 + c.token.length) == c.token;
		assert c.line > 100;
	}
}

test "the same seed gives byte-identical programs that keep the generated program intact" {
	const a = caseFor(7 as uint64);
	const b = caseFor(7 as uint64);
	assert a.legal == b.legal && a.mutant == b.mutant && a.message == b.message;
	const base = generate(7 as uint64, Features.defaults());
	assert base.endsWith("\n");
	assert a.legal.startsWith(base) && a.mutant.startsWith(base);
	assert caseFor(8 as uint64).mutant != a.mutant;
}

test "a seed range reaches every mutation kind, two variants of each, and both verdict sides" {
	const kinds: string[] = [];
	const variants: string[] = [];
	let refused = 0;
	let controls = 0;
	for (let seed = 1; seed <= 240; seed++) {
		const c = buildCase(seed as uint64, SMALL_BASE);
		if (c.message == "") { controls++; } else { refused++; }
		if (kinds.indexOf(c.kind) < 0) { kinds.push(c.kind); }
		if (variants.indexOf(c.kind + " " + c.variant) < 0) { variants.push(c.kind + " " + c.variant); }
	}
	assert kinds.length == KINDS.length;
	for (const k of KINDS) {
		let seen = 0;
		for (const v of variants) { if (v.startsWith(kindName(k) + " ")) { seen++; } }
		assert seen >= 2;
	}
	assert refused > 100 && controls > 20;
}

test "the verdict names what differs from the expectation" {
	const c = refusing("boom", 5, 3);
	const clean = observed(0, "", 0, 0);
	assert judge(c, clean, observed(1, "boom", 5, 3)) == "clean";
	assert judge(c, observed(1, "boom", 1, 1), observed(1, "boom", 5, 3)) == "false-alarm";
	assert judge(c, clean, clean) == "missed";
	assert judge(c, clean, { exit: 1, count: 0, message: "", line: 0, col: 0, text: "" }) == "crash";
	assert judge(c, clean, observed(1, "bang", 5, 3)) == "wrong-message";
	assert judge(c, clean, observed(1, "boom", 5, 4)) == "wrong-position";
	assert judge(c, clean, observed(1, "boom", 6, 3)) == "wrong-position";
	assert judge(c, clean, observed(2, "boom", 5, 3)) == "extra-errors";
	const control = refusing("", 0, 0);
	assert judge(control, clean, clean) == "clean";
	assert judge(control, clean, observed(1, "boom", 5, 3)) == "false-alarm";
}

test "a planted column shift is a wrong position, never a pass" {
	const c = caseFor(2 as uint64);
	assert c.message != "";
	const there = observed(1, c.message, c.line, c.col);
	assert judge(c, observed(0, "", 0, 0), there) == "clean";
	const shifted: Case = { ...c, col: c.col + 1 };
	assert judge(shifted, observed(0, "", 0, 0), there) == "wrong-position";
}

test "the first error line and its position are read from check output" {
	const one = "error: implicit int64 → int32 conversion narrows — 'wide' is declared int64, so its type decides, not its value 5; write an explicit 'as int32', or declare 'wide' without a type\n" +
		"  --> /w/b1.ms:3:19\n    |\n3 | \tconst n: int32 = wide;\n    |                   ^\n\n" +
		"error: 1 type error(s) found, stopping before codegen\n";
	const o = parseCheck(1, "", one);
	assert o.count == 1 && o.line == 3 && o.col == 19;
	assert o.message == "implicit int64 → int32 conversion narrows — 'wide' is declared int64, so its type decides, not its value 5; write an explicit 'as int32', or declare 'wide' without a type";
	const two = "error: Undefined variable 'a'\n  --> C:\\w\\u.ms:2:2\n\nerror: Undefined variable 'b'\n  --> C:\\w\\u.ms:3:6\n\nerror: 2 type error(s) found, stopping before codegen\n";
	const t = parseCheck(1, "", two);
	assert t.count == 2 && t.message == "Undefined variable 'a'" && t.line == 2 && t.col == 2;
	const parse = parseCheck(1, "", "error: Parse: Unexpected token: = at line 3\n  --> /w/kw.ms\n\n");
	assert parse.count == 1 && parse.line == 0 && parse.col == 0;
	const ok = parseCheck(0, "OK no type errors in 52 module(s)\n", "");
	assert isClean(ok) && ok.count == 0;
	const crash = parseCheck(1, "", "Error: unhandled exception: internal: assignment to 'a' at 2:2 reached flow narrowing with no symbol bound by position\n");
	assert !isClean(crash) && crash.count == 0;
}

test "the numeric lattice accepts exactly the conversions that lose no value" {
	let accepted = 0;
	for (const a of NUMS) {
		for (const b of NUMS) { if (a.name != b.name && convertible(a, b)) { accepted++; } }
	}
	assert accepted == 29;
	assert convertible(NUMS[0], NUMS[3]) && convertible(NUMS[4], NUMS[1]) && convertible(NUMS[5], NUMS[8]);
	assert !convertible(NUMS[6], NUMS[2]) && !convertible(NUMS[2], NUMS[8]) && !convertible(NUMS[9], NUMS[8]);
	assert convertible(NUMS[8], NUMS[9]) && !convertible(NUMS[9], NUMS[0]);
}

test "a refused conversion names its reason, its value and the fix" {
	assert narrowMessage(NUMS[3], NUMS[2], "wide", "5", "") ==
		"implicit int64 → int32 conversion narrows — 'wide' is declared int64, so its type decides, not its value 5; write an explicit 'as int32', or declare 'wide' without a type";
	assert narrowMessage(NUMS[6], NUMS[2], "w", "9", "+=") ==
		"implicit uint32 → int32 conversion in '+=' may exceed the target's maximum — 'w' is declared uint32, so its type decides, not its value 9; write an explicit 'as int32', or declare 'w' without a type";
	assert narrowMessage(NUMS[2], NUMS[4], "w", "9", "") ==
		"implicit int32 → uint8 conversion changes signedness — 'w' is declared int32, so its type decides, not its value 9; write an explicit 'as uint8', or declare 'w' without a type";
	assert narrowMessage(NUMS[9], NUMS[1], "w", "9.0", "") ==
		"implicit float64 → int16 conversion takes the float 9.0, and a float never becomes an integer implicitly — write an explicit 'as int16'";
	assert narrowMessage(NUMS[3], NUMS[9], "w", "9", "").contains("above 2^53");
	assert narrowMessage(NUMS[2], NUMS[8], "w", "9", "").contains("above 2^24");
	assert narrowMessage(NUMS[9], NUMS[8], "w", "9.0", "").contains("24-bit mantissa");
	assert narrowMessage(NUMS[0], NUMS[1], "w", "9", "") == "";
}

test "no generated name collides with an identifier the frame itself declares" {
	for (const n of PLAIN_NAMES) { assert FIXED_NAMES.indexOf(n) < 0 && KEYWORD_NAMES.indexOf(n) < 0; }
	for (const n of KEYWORD_NAMES) { assert FIXED_NAMES.indexOf(n) < 0; }
	for (const n of UNDEFINED_BARE_NAMES) { assert FIXED_NAMES.indexOf(n) < 0 && n != "get" && n != "set"; }
}
