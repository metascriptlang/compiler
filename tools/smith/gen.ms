import { Rng, seeded } from "./rng";
import { ALL_TYS, ALL_FAMS, Fam, Features, Plant, Ty, tyName, format } from "./features";

const FN_COST_CAP: int64 = 20000 as int64;
const TOP_COST_CAP: int64 = 200000 as int64;
const GEN_NODE_CAP: int32 = 4096;

enum Shape {
	Literal,
	Ternary,
	Other,
}

struct Var {
	name: string;
	ty: Ty;
	writable: boolean;
}

enum EntKind {
	Callable,
	Effect,
	ClosureArray,
	UnionVar,
	BoxVar,
}

struct Ent {
	kind: EntKind;
	name: string;
	ty: Ty;
	params: Ty[];
	len: int32;
	cost: int64;
}

struct Routine {
	text: string;
	cost: int64;
}

struct Fn {
	name: string;
	ret: Ty;
	params: Ty[];
	cost: int64;
}

function isFloat(t: Ty): boolean { return t == Ty.Float64; }

function isSigned(t: Ty): boolean {
	return t == Ty.Int8 || t == Ty.Int16 || t == Ty.Int32 || t == Ty.Int64;
}

function bitsOf(t: Ty): int32 {
	return match (t) {
		Ty.Int8 | Ty.Uint8 => 8,
		Ty.Int16 | Ty.Uint16 => 16,
		Ty.Int32 | Ty.Uint32 => 32,
		_ => 64,
	};
}

function trapsOnOverflow(t: Ty): boolean { return t == Ty.Int32 || t == Ty.Int64; }

function posMax(t: Ty): uint64 {
	return match (t) {
		Ty.Int8 => (127 as uint64),
		Ty.Int16 => (32767 as uint64),
		Ty.Int32 => (2147483647 as uint64),
		Ty.Int64 => (9223372036854775807 as uint64),
		Ty.Uint8 => (255 as uint64),
		Ty.Uint16 => (65535 as uint64),
		Ty.Uint32 => (4294967295 as uint64),
		_ => (18446744073709551615 as uint64),
	};
}

function negMax(t: Ty): uint64 {
	return match (t) {
		Ty.Int8 => (128 as uint64),
		Ty.Int16 => (32768 as uint64),
		Ty.Int32 => (2147483648 as uint64),
		Ty.Int64 => (9223372036854775808 as uint64),
		_ => (0 as uint64),
	};
}

function tyTitle(t: Ty): string {
	const name = tyName(t);
	return name.slice(0, 1).toUpperCase() + name.slice(1, name.length);
}

function intLiteral(t: Ty, negative: boolean, magnitude: uint64): string {
	const digits = String(magnitude);
	const minus = negative && magnitude != (0 as uint64);
	if (t == Ty.Int32) {
		if (!minus) { return digits; }
		if (magnitude == (2147483648 as uint64)) { return "((-2147483648) as int32)"; }
		return "(-" + digits + ")";
	}
	return minus ? "((-" + digits + ") as " + tyName(t) + ")" : "(" + digits + " as " + tyName(t) + ")";
}

function zero(t: Ty): string { return isFloat(t) ? "0.0" : intLiteral(t, false, 0 as uint64); }

function minLiteral(t: Ty): string { return intLiteral(t, true, negMax(t)); }

function maxLiteral(t: Ty): string { return intLiteral(t, false, posMax(t)); }

function fitsRaw(from: Ty, to: Ty): boolean {
	if (isFloat(to)) { return true; }
	if (isFloat(from)) { return false; }
	if (!isSigned(to)) { return true; }
	return isSigned(from) ? bitsOf(from) <= bitsOf(to) : bitsOf(from) < bitsOf(to);
}

function floatRangeTest(t: Ty): string {
	return match (t) {
		Ty.Int8 => "x > -129.0 && x < 128.0",
		Ty.Int16 => "x > -32769.0 && x < 32768.0",
		Ty.Int32 => "x > -2147483649.0 && x < 2147483648.0",
		Ty.Int64 => "x >= -9223372036854775808.0 && x < 9223372036854775808.0",
		Ty.Uint8 => "x > -1.0 && x < 256.0",
		Ty.Uint16 => "x > -1.0 && x < 65536.0",
		Ty.Uint32 => "x > -1.0 && x < 4294967296.0",
		_ => "x > -1.0 && x < 18446744073709551616.0",
	};
}

const FLOAT_EDGES: string[] = [
	"0.0",
	"1.0",
	"0.5",
	"0.1",
	"3.0",
	"1.0e300",
	"5.0e-324",
	"1.7976931348623157e308",
	"2.2250738585072014e-308",
	"1.0e-7",
	"1.0e21",
	"123456789.125",
	"1.0e16",
];

const INT_OPS: string[] = ["+", "-", "*", "/", "%", "&", "|", "^", "<<", ">>"];
const FLOAT_OPS: string[] = ["+", "-", "*", "/", "%"];
const CMP_OPS: string[] = ["==", "!=", "<", "<=", ">", ">="];

class Gen {
	rng: Rng = new Rng();
	tys: Ty[] = [];
	stmtMax: int32 = 1;
	depthMax: int32 = 1;
	exprMax: int32 = 1;
	tripMax: int32 = 1;
	globals: Var[] = [];
	scope: Var[] = [];
	fns: Fn[] = [];
	helperNames: string[] = [];
	helperText: string = "";
	localCount: int32 = 0;
	shape: Shape = Shape.Other;
	loopCount: int32 = 0;
	cost: int64 = 0 as int64;
	costCap: int64 = 0 as int64;
	mult: int64 = 1 as int64;
	fams: Fam[] = [];
	ents: Ent[] = [];
	entCount: int32 = 0;
	makerCount: int32 = 0;
	nodesLeft: int32 = GEN_NODE_CAP;

	pickTy(): Ty { return this.tys[this.rng.below(this.tys.length)]; }

	pickOp(ops: string[]): string { return ops[this.rng.below(ops.length)]; }

	reserve(work: int64): boolean {
		const remaining = this.costCap - this.cost;
		if (remaining < 0 || work > remaining / this.mult) { return false; }
		this.cost = this.cost + this.mult * work;
		return true;
	}

	spare(times: int64): int64 {
		const remaining = this.costCap - this.cost;
		if (remaining <= 0) { return 0 as int64; }
		const share = remaining / this.mult / times;
		return share < FN_COST_CAP ? share : FN_COST_CAP;
	}

	intTys(): Ty[] {
		const out: Ty[] = [];
		for (const t of this.tys) { if (!isFloat(t)) { out.push(t); } }
		return out;
	}

	magnitudeUpTo(max: uint64): uint64 {
		if (max == (18446744073709551615 as uint64)) { return this.rng.next(); }
		return this.rng.next() % (max + (1 as uint64));
	}

	intLit(t: Ty): string {
		const signed = isSigned(t);
		const k = this.rng.below(10);
		if (k < 4) { return intLiteral(t, signed && this.rng.chance(50), this.rng.below(17) as uint64); }
		if (k < 7) {
			const edge = this.rng.below(signed ? 7 : 4);
			return match (edge) {
				0 => intLiteral(t, false, 0 as uint64),
				1 => intLiteral(t, false, 1 as uint64),
				2 => intLiteral(t, false, posMax(t)),
				3 => intLiteral(t, false, posMax(t) - (1 as uint64)),
				4 => intLiteral(t, true, negMax(t)),
				5 => intLiteral(t, true, negMax(t) - (1 as uint64)),
				_ => intLiteral(t, true, 1 as uint64),
			};
		}
		if (k < 8) {
			const shift = this.rng.below(bitsOf(t) - (signed ? 1 : 0));
			return intLiteral(t, signed && this.rng.chance(50), (1 as uint64) << (shift as uint64));
		}
		const negative = signed && this.rng.chance(50);
		return intLiteral(t, negative, this.magnitudeUpTo(negative ? negMax(t) : posMax(t)));
	}

	floatLit(): string {
		const k = this.rng.below(10);
		let text = "";
		if (k < 3) {
			text = FLOAT_EDGES[this.rng.below(FLOAT_EDGES.length)];
		} else if (k < 7) {
			const frac = String(this.rng.below(1000) + 1000);
			text = String(this.rng.below(100000)) + "." + frac.slice(1, 4);
		} else {
			const frac = String(this.rng.below(1000) + 1000);
			text = String(this.rng.between(1, 9)) + "." + frac.slice(1, 4) + "e" + String(this.rng.between(-40, 40));
		}
		return this.rng.chance(30) ? "(-" + text + ")" : text;
	}

	literal(t: Ty): string { return isFloat(t) ? this.floatLit() : this.intLit(t); }

	visible(t: Ty, writableOnly: boolean): Var[] {
		const out: Var[] = [];
		for (const v of this.scope) {
			if (v.ty == t && (!writableOnly || v.writable)) { out.push(v); }
		}
		for (const v of this.globals) {
			if (v.ty == t) { out.push(v); }
		}
		return out;
	}

	leaf(t: Ty): string {
		const vars = this.visible(t, false);
		if (vars.length > 0 && this.rng.chance(70)) {
			this.shape = Shape.Other;
			return vars[this.rng.below(vars.length)].name;
		}
		this.shape = Shape.Literal;
		return this.literal(t);
	}

	useHelper(name: string, text: string): string {
		for (const n of this.helperNames) { if (n == name) { return name; } }
		this.helperNames.push(name);
		this.helperText += text;
		return name;
	}

	arithHelper(op: string, t: Ty): string {
		const T = tyName(t);
		const Z = zero(t);
		const MIN = minLiteral(t);
		const MAX = maxLiteral(t);
		const head = "(a: " + T + ", b: " + T + "): " + T + " {\n";
		if (op == "+") {
			return this.useHelper("safeAdd" + tyTitle(t), "function safeAdd" + tyTitle(t) + head +
				"\tif (((b > " + Z + ") && (a > " + MAX + " - b)) || ((b < " + Z + ") && (a < " + MIN + " - b))) { return a; }\n" +
				"\treturn a + b;\n}\n");
		}
		if (op == "-") {
			return this.useHelper("safeSub" + tyTitle(t), "function safeSub" + tyTitle(t) + head +
				"\tif (((b < " + Z + ") && (a > " + MAX + " + b)) || ((b > " + Z + ") && (a < " + MIN + " + b))) { return a; }\n" +
				"\treturn a - b;\n}\n");
		}
		if (op == "*") {
			return this.useHelper("safeMul" + tyTitle(t), "function safeMul" + tyTitle(t) + head +
				"\tif (a > " + Z + ") {\n" +
				"\t\tif (b > " + Z + ") { if (a > " + MAX + " / b) { return a; } }\n" +
				"\t\telse { if (b < " + MIN + " / a) { return a; } }\n" +
				"\t} else {\n" +
				"\t\tif (b > " + Z + ") { if (a < " + MIN + " / b) { return a; } }\n" +
				"\t\telse { if (a != " + Z + " && b < " + MAX + " / a) { return a; } }\n" +
				"\t}\n" +
				"\treturn a * b;\n}\n");
		}
		const name = (op == "/" ? "safeDiv" : "safeMod") + tyTitle(t);
		const minusOne = trapsOnOverflow(t) ? " || (a == " + MIN + " && b == " + intLiteral(t, true, 1 as uint64) + ")" : "";
		return this.useHelper(name, "function " + name + head +
			"\tif (b == " + Z + minusOne + ") { return a; }\n" +
			"\treturn a " + op + " b;\n}\n");
	}

	negHelper(t: Ty): string {
		const T = tyName(t);
		return this.useHelper("safeNeg" + tyTitle(t), "function safeNeg" + tyTitle(t) + "(a: " + T + "): " + T + " {\n" +
			"\tif (a == " + minLiteral(t) + ") { return a; }\n" +
			"\treturn -a;\n}\n");
	}

	convHelper(from: Ty, to: Ty): string {
		const name = "conv" + tyTitle(from) + "To" + tyTitle(to);
		let inRange = "";
		if (isFloat(from)) {
			inRange = floatRangeTest(to);
		} else if (isSigned(from)) {
			inRange = "(x >= (" + minLiteral(to) + " as " + tyName(from) + ")) && (x <= (" + maxLiteral(to) + " as " + tyName(from) + "))";
		} else {
			inRange = "x <= (" + maxLiteral(to) + " as " + tyName(from) + ")";
		}
		return this.useHelper(name, "function " + name + "(x: " + tyName(from) + "): " + tyName(to) + " {\n" +
			"\tif (" + inRange + ") { return x as " + tyName(to) + "; }\n" +
			"\treturn " + zero(to) + ";\n}\n");
	}

	wrapHelper(from: Ty, to: Ty): string {
		const name = "wrap" + tyTitle(from) + "To" + tyTitle(to);
		return this.useHelper(name, "function " + name + "(x: " + tyName(from) + "): " + tyName(to) + " {\n" +
			"\treturn x as " + tyName(to) + ";\n}\n");
	}

	binary(t: Ty, depth: int32): string {
		const a = this.expr(t, depth + 1);
		const b = this.expr(t, depth + 1);
		if (isFloat(t)) { return "(" + a + " " + this.pickOp(FLOAT_OPS) + " " + b + ")"; }
		const op = this.pickOp(INT_OPS);
		const guarded = op == "/" || op == "%" || (trapsOnOverflow(t) && (op == "+" || op == "-" || op == "*"));
		if (guarded) { return this.arithHelper(op, t) + "(" + a + ", " + b + ")"; }
		return "(" + a + " " + op + " " + b + ")";
	}

	unary(t: Ty, depth: int32): string {
		const a = this.expr(t, depth + 1);
		if (isFloat(t)) { return "(-" + a + ")"; }
		if (!isSigned(t) || this.rng.chance(40)) { return "(~" + a + ")"; }
		if (trapsOnOverflow(t)) { return this.negHelper(t) + "(" + a + ")"; }
		return "(-" + a + ")";
	}

	convert(t: Ty, depth: int32): string {
		if (this.tys.length < 2) { return this.binary(t, depth); }
		const alternatives: Ty[] = [];
		for (const from of this.tys) { if (from != t) { alternatives.push(from); } }
		const from = alternatives[this.rng.below(alternatives.length)];
		const a = this.expr(from, depth + 1);
		const checkedAtCompileTime = this.shape != Shape.Other;
		if (checkedAtCompileTime && isSigned(from) && !isSigned(t) && !isFloat(t)) { return this.wrapHelper(from, t) + "(" + a + ")"; }
		if (fitsRaw(from, t)) { return "(" + a + " as " + tyName(t) + ")"; }
		return this.convHelper(from, t) + "(" + a + ")";
	}

	cond(depth: int32): string {
		if (this.nodesLeft == 0 || !this.reserve(1 as int64)) {
			const t = this.pickTy();
			return "(" + this.leaf(t) + " == " + this.leaf(t) + ")";
		}
		this.nodesLeft--;
		if (depth >= this.exprMax || this.rng.chance(60)) {
			const t = this.pickTy();
			const a = this.expr(t, depth + 1);
			const b = this.expr(t, depth + 1);
			return "(" + a + " " + this.pickOp(CMP_OPS) + " " + b + ")";
		}
		const k = this.rng.below(3);
		if (k == 0) { return "(!" + this.cond(depth + 1) + ")"; }
		const a = this.cond(depth + 1);
		const b = this.cond(depth + 1);
		return "(" + a + (k == 1 ? " && " : " || ") + b + ")";
	}

	call(t: Ty, depth: int32): string {
		const candidates: Fn[] = [];
		for (const f of this.fns) { if (f.ret == t) { candidates.push(f); } }
		if (candidates.length == 0) { return ""; }
		const f = candidates[this.rng.below(candidates.length)];
		if (!this.reserve(f.cost + (1 as int64))) { return ""; }
		let args = "";
		for (const p of f.params) {
			const a = this.expr(p, depth + 1);
			args = args == "" ? a : args + ", " + a;
		}
		return f.name + "(" + args + ")";
	}

	expr(t: Ty, depth: int32): string {
		if (this.nodesLeft == 0) { return this.leaf(t); }
		this.nodesLeft--;
		if (depth >= this.exprMax || !this.reserve(1 as int64)) { return this.leaf(t); }
		if (this.fams.length > 0 && this.rng.chance(20)) {
			const fam = this.famExpr(t, depth);
			if (fam != "") {
				this.shape = Shape.Other;
				return fam;
			}
		}
		const k = this.rng.below(100);
		if (k < 25) { return this.leaf(t); }
		let out = "";
		let shape = Shape.Other;
		if (k < 55) {
			out = this.binary(t, depth);
		} else if (k < 63) {
			out = this.unary(t, depth);
		} else if (k < 73) {
			out = this.convert(t, depth);
		} else if (k < 81) {
			out = "(" + this.cond(depth + 1) + " ? " + this.expr(t, depth + 1) + " : " + this.expr(t, depth + 1) + ")";
			shape = Shape.Ternary;
		} else {
			const c = this.call(t, depth);
			out = c != "" ? c : this.binary(t, depth);
		}
		this.shape = shape;
		return out;
	}

	has(f: Fam): boolean {
		for (const g of this.fams) { if (g == f) { return true; } }
		return false;
	}

	entsOf(kind: EntKind, t: Ty): Ent[] {
		const out: Ent[] = [];
		for (const e of this.ents) { if (e.kind == kind && e.ty == t) { out.push(e); } }
		return out;
	}

	entName(prefix: string): string {
		const name = prefix + String(this.entCount);
		this.entCount = this.entCount + 1;
		return name;
	}

	args(params: Ty[], depth: int32): string {
		let out = "";
		for (const p of params) {
			const a = this.expr(p, depth + 1);
			out = out == "" ? a : out + ", " + a;
		}
		return out;
	}

	routine(t: Ty, depth: int32, cap: int64): Routine {
		const savedCost = this.cost;
		const savedCap = this.costCap;
		const savedMult = this.mult;
		this.cost = 0 as int64;
		this.costCap = cap;
		this.mult = 1 as int64;
		const text = this.expr(t, depth);
		const cost = this.cost;
		this.cost = savedCost;
		this.costCap = savedCap;
		this.mult = savedMult;
		return { text: text, cost: cost };
	}

	lambda(params: Ty[], ret: Ty, depth: int32, cap: int64): Routine {
		const saved = this.scope.length;
		let sig = "";
		for (const p of params) {
			const name = this.entName("q");
			this.scope.push({ name: name, ty: p, writable: false });
			sig = sig == "" ? name + ": " + tyName(p) : sig + ", " + name + ": " + tyName(p);
		}
		const body = this.routine(ret, depth + 1, cap);
		while (this.scope.length > saved) { this.scope.pop(); }
		return { text: "(" + sig + "): " + tyName(ret) + " => " + body.text, cost: body.cost };
	}

	smallInt(depth: int32): string {
		for (const t of this.tys) {
			if (t == Ty.Int32) { return this.expr(Ty.Int32, depth + 1); }
		}
		return String(this.rng.below(9));
	}

	famExpr(t: Ty, depth: int32): string {
		const fam = this.fams[this.rng.below(this.fams.length)];
		if (fam == Fam.Closure) { return this.closureExpr(t, depth); }
		if (fam == Fam.Union) { return this.unionExpr(t, depth); }
		return this.genericExpr(t, depth);
	}

	closureExpr(t: Ty, depth: int32): string {
		const k = this.rng.below(3);
		if (k == 0) {
			const named = this.entsOf(EntKind.Callable, t);
			if (named.length > 0) {
				const c = named[this.rng.below(named.length)];
				if (this.reserve(c.cost + (1 as int64))) { return c.name + "(" + this.args(c.params, depth) + ")"; }
			}
		}
		if (k == 1) {
			const arrays = this.entsOf(EntKind.ClosureArray, t);
			if (arrays.length > 0) {
				const a = arrays[this.rng.below(arrays.length)];
				if (this.reserve(a.cost + (1 as int64))) {
					return a.name + "[" + String(this.rng.below(a.len)) + "](" + this.expr(t, depth + 1) + ")";
				}
			}
		}
		const params: Ty[] = [];
		const n = this.rng.between(1, 2);
		for (let i = 0; i < n; i++) { params.push(this.pickTy()); }
		const f = this.lambda(params, t, depth, this.spare(1 as int64));
		if (!this.reserve(f.cost)) { return ""; }
		return "(" + f.text + ")(" + this.args(params, depth) + ")";
	}

	unionHelpers(t: Ty): string {
		const T = tyName(t);
		const U = T + " | string | null";
		this.useHelper("boxU" + tyTitle(t), "function boxU" + tyTitle(t) + "(k: int32, v: " + T + "): " + U + " {\n" +
			"\tconst r = k % 3;\n" +
			"\tif (r == 0) { return null; }\n" +
			"\tif (r == 1 || r == -1) { return \"s\" + String(v); }\n" +
			"\treturn v;\n}\n");
		this.useHelper("lenU" + tyTitle(t), "function lenU" + tyTitle(t) + "(u: " + U + "): int32 {\n" +
			"\tif (u === null) { return -1; }\n" +
			"\tif (typeof u === \"string\") { return u.length; }\n" +
			"\treturn 0;\n}\n");
		return this.useHelper("unboxU" + tyTitle(t), "function unboxU" + tyTitle(t) + "(u: " + U + ", d: " + T + "): " + T + " {\n" +
			"\tif (u === null) { return d; }\n" +
			"\tif (typeof u === \"string\") { return d; }\n" +
			"\treturn u;\n}\n");
	}

	unionExpr(t: Ty, depth: int32): string {
		if (t == Ty.Int32 && this.rng.chance(30)) {
			const s = this.pickTy();
			this.unionHelpers(s);
			const vars = this.entsOf(EntKind.UnionVar, s);
			const u = vars.length > 0 && this.rng.chance(60)
				? vars[this.rng.below(vars.length)].name
				: "boxU" + tyTitle(s) + "(" + this.smallInt(depth) + ", " + this.expr(s, depth + 1) + ")";
			return "lenU" + tyTitle(s) + "(" + u + ")";
		}
		const unbox = this.unionHelpers(t);
		const vars = this.entsOf(EntKind.UnionVar, t);
		if (vars.length > 0 && this.rng.chance(60)) {
			return unbox + "(" + vars[this.rng.below(vars.length)].name + ", " + this.expr(t, depth + 1) + ")";
		}
		return unbox + "(boxU" + tyTitle(t) + "(" + this.smallInt(depth) + ", " + this.expr(t, depth + 1) + "), " + this.expr(t, depth + 1) + ")";
	}

	genericHelpers(): void {
		this.useHelper("idG", "function idG<T>(x: T): T { return x; }\n");
		this.useHelper("twiceG", "function twiceG<T>(f: (x: T) => T, x: T): T { return f(f(x)); }\n");
		this.useHelper("pickG", "function pickG<T>(xs: T[], i: int32, d: T): T { return i >= 0 && i < xs.length ? xs[i] : d; }\n");
		this.useHelper("BoxG", "class BoxG<T> {\n" +
			"\tv: T;\n" +
			"\tconstructor(v: T) { this.v = v; }\n" +
			"\tget(): T { return this.v; }\n" +
			"\tmap<U>(f: (x: T) => U): BoxG<U> { return new BoxG<U>(f(this.v)); }\n" +
			"}\n");
	}

	genericExpr(t: Ty, depth: int32): string {
		this.genericHelpers();
		const T = tyName(t);
		const k = this.rng.below(6);
		if (k == 0) { return "idG<" + T + ">(" + this.expr(t, depth + 1) + ")"; }
		if (k == 1) {
			const f = this.lambda([t], t, depth, this.spare(2 as int64));
			if (!this.reserve((2 as int64) * f.cost)) { return ""; }
			return "twiceG<" + T + ">(" + f.text + ", " + this.expr(t, depth + 1) + ")";
		}
		if (k == 2) {
			const n = this.rng.between(1, 3);
			let items = "";
			for (let i = 0; i < n; i++) {
				const e = this.expr(t, depth + 1);
				items = items == "" ? e : items + ", " + e;
			}
			return "pickG<" + T + ">([" + items + "], " + String(this.rng.below(n + 1)) + ", " + this.expr(t, depth + 1) + ")";
		}
		if (k == 3) {
			const s = this.pickTy();
			const f = this.lambda([s], t, depth, this.spare(1 as int64));
			if (!this.reserve(f.cost)) { return ""; }
			return "new BoxG<" + tyName(s) + ">(" + this.expr(s, depth + 1) + ").map<" + T + ">(" + f.text + ").get()";
		}
		const boxes = this.entsOf(EntKind.BoxVar, t);
		if (boxes.length > 0) { return boxes[this.rng.below(boxes.length)].name + ".get()"; }
		return "new BoxG<" + T + ">(" + this.expr(t, depth + 1) + ").get()";
	}

	maker(t: Ty): Routine {
		const name = "mk" + String(this.makerCount);
		this.makerCount = this.makerCount + 1;
		const T = tyName(t);
		const savedScope = this.scope;
		const savedEnts = this.ents;
		this.scope = [{ name: "st", ty: t, writable: true }, { name: "x", ty: t, writable: false }];
		this.ents = [];
		const next = this.routine(t, 1, FN_COST_CAP);
		this.scope = savedScope;
		this.ents = savedEnts;
		this.useHelper(name, "function " + name + "(seed: " + T + "): (x: " + T + ") => " + T + " {\n" +
			"\tlet st: " + T + " = seed;\n" +
			"\treturn (x: " + T + "): " + T + " => {\n" +
			"\t\tst = " + next.text + ";\n" +
			"\t\treturn st;\n" +
			"\t};\n}\n");
		return { text: name, cost: next.cost };
	}

	famStatement(indent: string): string {
		const fam = this.fams[this.rng.below(this.fams.length)];
		const t = this.pickTy();
		const T = tyName(t);
		if (fam == Fam.Closure) {
			const k = this.rng.below(5);
			if (k == 0) {
				const params: Ty[] = [];
				const n = this.rng.below(3);
				for (let i = 0; i < n; i++) { params.push(this.pickTy()); }
				const name = this.entName("c");
				const f = this.lambda(params, t, 0, FN_COST_CAP);
				this.ents.push({ kind: EntKind.Callable, name: name, ty: t, params: params, len: 0, cost: f.cost });
				return indent + "const " + name + " = " + f.text + ";\n";
			}
			if (k == 1) {
				const vars = this.visible(t, true);
				if (vars.length == 0) { return ""; }
				const v = vars[this.rng.below(vars.length)];
				const name = this.entName("c");
				const d = this.entName("q");
				this.scope.push({ name: d, ty: t, writable: false });
				const body = this.routine(t, 1, FN_COST_CAP);
				this.scope.pop();
				this.ents.push({ kind: EntKind.Effect, name: name, ty: t, params: [t], len: 0, cost: body.cost });
				const decl = indent + "const " + name + " = (" + d + ": " + T + "): void => { " + v.name + " = " + body.text + "; };\n";
				if (!this.reserve(body.cost + (1 as int64))) { return decl; }
				return decl + indent + name + "(" + this.expr(t, 0) + ");\n";
			}
			if (k == 2) {
				const effects = this.entsOf(EntKind.Effect, t);
				if (effects.length == 0) { return ""; }
				const e = effects[this.rng.below(effects.length)];
				if (!this.reserve(e.cost + (1 as int64))) { return ""; }
				return indent + e.name + "(" + this.expr(t, 0) + ");\n";
			}
			if (k == 3) {
				const mk = this.maker(t);
				const name = this.entName("k");
				const text = indent + "const " + name + " = " + mk.text + "(" + this.expr(t, 0) + ");\n";
				this.ents.push({ kind: EntKind.Callable, name: name, ty: t, params: [t], len: 0, cost: mk.cost });
				return text;
			}
			const name = this.entName("a");
			const j = this.entName("j");
			const n = this.rng.between(1, 4);
			this.scope.push({ name: j, ty: Ty.Int32, writable: false });
			const body = this.lambda([t], t, 0, FN_COST_CAP);
			this.scope.pop();
			this.ents.push({ kind: EntKind.ClosureArray, name: name, ty: t, params: [t], len: n, cost: body.cost });
			return indent + "const " + name + ": ((x: " + T + ") => " + T + ")[] = [];\n" +
				indent + "for (let " + j + ": int32 = 0; " + j + " < " + String(n) + "; " + j + "++) { " + name + ".push(" + body.text + "); }\n";
		}
		if (fam == Fam.Union) {
			this.unionHelpers(t);
			const vars = this.entsOf(EntKind.UnionVar, t);
			if (vars.length > 0 && this.rng.chance(50)) {
				const u = vars[this.rng.below(vars.length)];
				const k = this.rng.below(3);
				const value = k == 0 ? "null" : k == 1 ? "\"s\" + String(" + this.expr(t, 0) + ")" : this.expr(t, 0);
				return indent + u.name + " = " + value + ";\n";
			}
			const name = this.entName("u");
			const text = indent + "let " + name + ": " + T + " | string | null = boxU" + tyTitle(t) + "(" + this.smallInt(0) + ", " + this.expr(t, 0) + ");\n";
			this.ents.push({ kind: EntKind.UnionVar, name: name, ty: t, params: [], len: 0, cost: 0 as int64 });
			return text;
		}
		this.genericHelpers();
		const boxes = this.entsOf(EntKind.BoxVar, t);
		if (boxes.length > 0 && this.rng.chance(50)) {
			return indent + boxes[this.rng.below(boxes.length)].name + ".v = " + this.expr(t, 0) + ";\n";
		}
		const name = this.entName("b");
		const text = indent + "const " + name + " = new BoxG<" + T + ">(" + this.expr(t, 0) + ");\n";
		this.ents.push({ kind: EntKind.BoxVar, name: name, ty: t, params: [], len: 0, cost: 0 as int64 });
		return text;
	}

	newLocal(t: Ty): string {
		const name = "l" + String(this.localCount);
		this.localCount = this.localCount + 1;
		this.scope.push({ name: name, ty: t, writable: true });
		return name;
	}

	matchLet(indent: string): string {
		const ints = this.intTys();
		if (ints.length == 0) { return ""; }
		const s = ints[this.rng.below(ints.length)];
		const t = this.pickTy();
		const scrutinee = this.expr(s, 1);
		const used: int32[] = [];
		let arms = "";
		const armCount = this.rng.between(1, 3);
		for (let a = 0; a < armCount; a++) {
			let pattern = "";
			const alternatives = this.rng.between(1, 2);
			for (let k = 0; k < alternatives; k++) {
				const v = isSigned(s) ? this.rng.between(-8, 8) : this.rng.below(17);
				let seen = false;
				for (const u of used) { if (u == v) { seen = true; } }
				if (seen) { continue; }
				used.push(v);
				pattern = pattern == "" ? String(v) : pattern + " | " + String(v);
			}
			if (pattern == "") { continue; }
			arms += indent + "\t" + pattern + " => " + this.expr(t, 1) + ",\n";
		}
		arms += indent + "\t_ => " + this.expr(t, 1) + ",\n";
		const name = this.newLocal(t);
		return indent + "let " + name + ": " + tyName(t) + " = match (" + scrutinee + ") {\n" + arms + indent + "};\n";
	}

	statement(depth: int32, indent: string, inLoop: boolean, ret: Ty, inFn: boolean): string {
		this.nodesLeft--;
		if (!this.reserve(1 as int64)) { return ""; }
		if (this.fams.length > 0 && this.rng.chance(20)) {
			const fam = this.famStatement(indent);
			if (fam != "") { return fam; }
		}
		const nested = depth < this.depthMax;
		const k = this.rng.below(100);
		if (k < 25) {
			const t = this.pickTy();
			const value = this.expr(t, 0);
			return indent + "let " + this.newLocal(t) + ": " + tyName(t) + " = " + value + ";\n";
		}
		if (k < 50) {
			const t = this.pickTy();
			const vars = this.visible(t, true);
			if (vars.length > 0) {
				const v = vars[this.rng.below(vars.length)];
				return indent + v.name + " = " + this.expr(t, 0) + ";\n";
			}
		}
		if (k < 58) {
			const t = this.pickTy();
			const vars = this.visible(t, true);
			if (vars.length > 0 && !trapsOnOverflow(t)) {
				const v = vars[this.rng.below(vars.length)];
				const op = ["+=", "-=", "*="][this.rng.below(3)];
				return indent + v.name + " " + op + " " + this.expr(t, 0) + ";\n";
			}
		}
		if (k < 70 && nested) {
			let text = indent + "if " + this.cond(0) + " {\n" + this.block(depth + 1, indent + "\t", inLoop, ret, inFn) + indent + "}";
			if (this.rng.chance(50)) { text += " else {\n" + this.block(depth + 1, indent + "\t", inLoop, ret, inFn) + indent + "}"; }
			return text + "\n";
		}
		const available = (this.costCap - this.cost) / this.mult;
		const maxTrips = Math.min(this.tripMax, (available / (3 as int64)) as int32);
		if (k < 82 && nested && maxTrips > 0) {
			const name = "i" + String(this.loopCount);
			this.loopCount = this.loopCount + 1;
			const trips = this.rng.between(1, maxTrips);
			if (!this.reserve((2 * trips) as int64)) { return ""; }
			const savedMult = this.mult;
			this.mult = this.mult * (trips as int64);
			this.scope.push({ name: name, ty: Ty.Int32, writable: false });
			const body = this.block(depth + 1, indent + "\t", true, ret, inFn);
			this.scope.pop();
			this.mult = savedMult;
			return indent + "for (let " + name + ": int32 = 0; " + name + " < " + String(trips) + "; " + name + "++) {\n" +
				body + indent + "}\n";
		}
		if (k < 88) {
			const m = this.matchLet(indent);
			if (m != "") { return m; }
		}
		if (k < 94 && inLoop) {
			return indent + "if " + this.cond(0) + " { " + (this.rng.chance(50) ? "break" : "continue") + "; }\n";
		}
		if (inFn && this.rng.chance(50)) {
			return indent + "if " + this.cond(0) + " { return " + this.expr(ret, 0) + "; }\n";
		}
		const t = this.pickTy();
		const value = this.expr(t, 0);
		return indent + "let " + this.newLocal(t) + ": " + tyName(t) + " = " + value + ";\n";
	}

	block(depth: int32, indent: string, inLoop: boolean, ret: Ty, inFn: boolean): string {
		const saved = this.scope.length;
		const savedEnts = this.ents.length;
		const n = this.rng.between(1, this.stmtMax);
		let out = "";
		for (let i = 0; i < n; i++) {
			if (this.nodesLeft == 0 || this.cost + this.mult > this.costCap) { break; }
			out += this.statement(depth, indent, inLoop, ret, inFn);
		}
		while (this.scope.length > saved) { this.scope.pop(); }
		while (this.ents.length > savedEnts) { this.ents.pop(); }
		return out;
	}

	fn(index: int32): string {
		const ret = this.pickTy();
		const params: Ty[] = [];
		const paramCount = this.rng.below(4);
		let sig = "";
		this.scope = [];
		this.ents = [];
		this.entCount = 0;
		this.localCount = 0;
		this.loopCount = 0;
		this.cost = 0 as int64;
		this.costCap = FN_COST_CAP;
		this.mult = 1 as int64;
		for (let p = 0; p < paramCount; p++) {
			const t = this.pickTy();
			params.push(t);
			const name = "p" + String(p);
			this.scope.push({ name: name, ty: t, writable: false });
			sig = sig == "" ? name + ": " + tyName(t) : sig + ", " + name + ": " + tyName(t);
		}
		const body = this.block(0, "\t", false, ret, true);
		this.ents = [];
		const tail = "\treturn " + this.expr(ret, 0) + ";\n";
		const name = "f" + String(index);
		this.fns.push({ name: name, ret: ret, params: params, cost: this.cost });
		return "function " + name + "(" + sig + "): " + tyName(ret) + " {\n" + body + tail + "}\n";
	}
}

function plantDecls(plant: Plant): string {
	if (plant == Plant.None) { return ""; }
	const flag = plant == Plant.Backend ? "js" : "debug";
	const inside = plant == Plant.Backend ? "1" : "0";
	const outside = plant == Plant.Backend ? "0" : "1";
	return "when (" + flag + ") {\n" +
		"\tfunction plantDelta(): int32 { return " + inside + "; }\n" +
		"} else {\n" +
		"\tfunction plantDelta(): int32 { return " + outside + "; }\n" +
		"}\n";
}

export function generate(seed: uint64, f: Features): string {
	const g = new Gen();
	g.rng = Rng.seeded(seed);
	for (const t of ALL_TYS) { if (f.types.has(t)) { g.tys.push(t); } }
	for (const m of ALL_FAMS) { if (f.fams.has(m)) { g.fams.push(m); } }
	g.stmtMax = f.stmts;
	g.depthMax = f.depth;
	g.exprMax = f.exprDepth;
	g.tripMax = f.trips;

	let globals = "";
	for (let i = 0; i < f.globals; i++) {
		const t = g.pickTy();
		const name = "g" + String(i);
		globals += "let " + name + ": " + tyName(t) + " = " + g.literal(t) + ";\n";
		g.globals.push({ name: name, ty: t, writable: true });
	}

	let fns = "";
	for (let i = 0; i < f.funcs; i++) { fns += g.fn(i) + "\n"; }

	g.scope = [];
	g.cost = 0 as int64;
	g.costCap = TOP_COST_CAP;
	g.mult = 1 as int64;
	let entries = "";
	for (let e = 0; e < f.entries; e++) {
		const target = g.fns[g.rng.below(g.fns.length)];
		const value = g.call(target.ret, 0);
		if (value == "") { continue; }
		entries += "console.log(\"e" + String(e) + " \" + String(" + value + "));\n";
	}

	let plantSite = "";
	if (f.plant != Plant.None) {
		for (const v of g.globals) {
			if (plantSite == "" && !isFloat(v.ty)) {
				plantSite = v.name + " = " + v.name + " ^ (plantDelta() as " + tyName(v.ty) + ");\n";
			}
		}
		if (plantSite == "") { plantSite = "console.log(\"plant \" + String(plantDelta()));\n"; }
	}

	let prints = "";
	for (const v of g.globals) { prints += "console.log(\"" + v.name + " \" + String(" + v.name + "));\n"; }

	return "// smith seed=" + String(seed) + " features=" + f.format() + "\n" +
		g.helperText + plantDecls(f.plant) + globals + "\n" + fns + entries + plantSite + prints;
}

test "the same seed and features give the same program" {
	const f = Features.defaults();
	assert generate(11 as uint64, f) == generate(11 as uint64, f);
}

test "different seeds give different programs" {
	const f = Features.defaults();
	assert generate(11 as uint64, f) != generate(12 as uint64, f);
}

test "numeric loop and routine weights stay capped and restore their scope" {
	for (let seed = 1; seed < 13; seed++) {
		const g = new Gen();
		g.rng = Rng.seeded(seed as uint64);
		g.tys = [Ty.Int8, Ty.Int64, Ty.Float64];
		g.stmtMax = 32;
		g.depthMax = 8;
		g.exprMax = 8;
		g.tripMax = 64;
		g.fams = seed % 2 == 0 ? [Fam.Closure, Fam.Union, Fam.Generic] : [];
		g.fn(0);
		assert g.cost <= FN_COST_CAP;
		assert g.fns[0].cost <= FN_COST_CAP;
		assert g.mult == (1 as int64);
		assert g.scope.length == g.fns[0].params.length;
		assert g.ents.length == 0;
	}
}

test "a call is refused before its weighted product could overflow" {
	const g = new Gen();
	g.rng = Rng.seeded(1 as uint64);
	g.mult = FN_COST_CAP;
	g.costCap = FN_COST_CAP;
	g.fns = [{
		name: "huge",
		ret: Ty.Int8,
		params: [],
		cost: 9223372036854775806 as int64,
	}];
	assert g.call(Ty.Int8, 0) == "";
	assert g.cost == (0 as int64);
}

test "call overhead is charged for every loop iteration" {
	const g = new Gen();
	g.rng = Rng.seeded(1 as uint64);
	g.mult = 64 as int64;
	g.costCap = 63 as int64;
	g.fns = [{ name: "tiny", ret: Ty.Int8, params: [], cost: 0 as int64 }];
	assert g.call(Ty.Int8, 0) == "";
	assert g.cost == (0 as int64);
}

test "an exhausted weighted budget emits no block and preserves scope" {
	for (const t of [Ty.Int8, Ty.Float64]) {
		const g = new Gen();
		g.rng = Rng.seeded(1 as uint64);
		g.tys = [t];
		g.costCap = FN_COST_CAP;
		g.cost = FN_COST_CAP - (1 as int64);
		g.mult = 64 as int64;
		const text = g.block(0, "", false, t, true);
		assert text == "";
		assert g.cost == FN_COST_CAP - (1 as int64);
		assert g.scope.length == 0 && g.ents.length == 0;
	}
}

test "a legal deep vector cannot explode generated source" {
	const parsed = Features.defaults().overlay(
		"fams=none funcs=1 globals=1 stmts=32 depth=4 expr=1 trips=64 entries=1",
	);
	assert parsed.ok;
	if (parsed.ok) {
		assert generate(1 as uint64, parsed.value).byteLength < 1048576;
	}
}

test "the program head names its seed and full feature vector" {
	const f = Features.defaults();
	const text = generate(5 as uint64, f);
	assert text.startsWith("// smith seed=5 features=" + f.format() + "\n");
}

test "a planted program declares the plant on both sides of its flag" {
	const f: Features = { ...Features.defaults(), plant: Plant.Opt };
	const text = generate(5 as uint64, f);
	assert text.contains("when (debug) {");
	assert text.contains("plantDelta()");
}

test "fams=none emits no closure, union or generic construct" {
	const r = Features.defaults().overlay("fams=none");
	assert r.ok;
	if (r.ok) {
		for (let seed = 1; seed < 9; seed++) {
			const text = generate(seed as uint64, r.value);
			assert !text.contains("(q");
			assert !text.contains("| string | null");
			assert !text.contains("BoxG");
		}
	}
}

test "each family alone reaches the program" {
	const closure = Features.defaults().overlay("fams=closure");
	const union = Features.defaults().overlay("fams=union");
	const generic = Features.defaults().overlay("fams=generic");
	assert closure.ok && union.ok && generic.ok;
	if (closure.ok && union.ok && generic.ok) {
		let c = false;
		let u = false;
		let g = false;
		for (let seed = 1; seed < 9; seed++) {
			if (generate(seed as uint64, closure.value).contains("(q")) { c = true; }
			if (generate(seed as uint64, union.value).contains("| string | null")) { u = true; }
			if (generate(seed as uint64, generic.value).contains("<T>")) { g = true; }
		}
		assert c && u && g;
	}
}

test "an exhausted budget emits one leaf for an expression or condition" {
	for (let seed = 1; seed < 21; seed++) {
		const g = new Gen();
		g.rng = Rng.seeded(seed as uint64);
		g.tys = [Ty.Int32, Ty.Float64];
		g.exprMax = 8;
		g.fams = [Fam.Closure, Fam.Union, Fam.Generic];
		g.expr(Ty.Int32, 0);
		g.cond(0);
		assert g.nodesLeft == GEN_NODE_CAP - 1;
		assert g.cost == (0 as int64);
	}
}

test "a named closure is invoked only when its weighted body fits" {
	for (const bodyCost of [0 as int64, FN_COST_CAP]) {
		let invoked = false;
		for (let seed = 1; seed < 41; seed++) {
			const g = new Gen();
			g.rng = Rng.seeded(seed as uint64);
			g.tys = [Ty.Int32];
			g.exprMax = 4;
			g.fams = [Fam.Closure];
			g.costCap = FN_COST_CAP;
			g.mult = 2 as int64;
			g.ents = [{ kind: EntKind.Callable, name: "c0", ty: Ty.Int32, params: [], len: 0, cost: bodyCost }];
			if (g.closureExpr(Ty.Int32, 0).contains("c0(")) { invoked = true; }
			assert g.cost <= g.costCap;
		}
		assert invoked == (bodyCost == (0 as int64));
	}
}

function countOf(text: string, needle: string): int32 {
	let n = 0;
	let at = text.indexOf(needle);
	while (at >= 0) {
		n++;
		at = text.indexOf(needle, at + needle.length);
	}
	return n;
}

function firstArg(call: string): string {
	let depth = 0;
	const open = call.indexOf("(");
	for (let i = open + 1; i < call.length; i++) {
		const c = call.slice(i, i + 1);
		if (c == "(") { depth++; }
		if (c == ")") { depth--; }
		if (depth == 0 && c == ",") { return call.slice(open + 1, i); }
	}
	return "";
}

test "a callback body may call a routine and is charged once per invocation" {
	let reached = false;
	for (let seed = 1; seed < 81; seed++) {
		const g = new Gen();
		g.rng = Rng.seeded(seed as uint64);
		g.tys = [Ty.Int32];
		g.exprMax = 3;
		g.fams = [Fam.Closure, Fam.Generic];
		g.costCap = FN_COST_CAP;
		g.fns = [{ name: "f0", ret: Ty.Int32, params: [], cost: 100 as int64 }];
		const text = g.famExpr(Ty.Int32, 0);
		const calls = countOf(text, "f0(");
		const twice = text.startsWith("twiceG<") ? countOf(firstArg(text), "f0(") : 0;
		if (calls > 0 && text.contains("=>")) { reached = true; }
		assert g.cost >= (((calls + twice) * 101) as int64);
		assert g.cost <= g.costCap;
	}
	assert reached;
}

test "a deferred closure body keeps its own budget" {
	let shaped = false;
	for (let seed = 1; seed < 21; seed++) {
		const g = new Gen();
		g.rng = Rng.seeded(seed as uint64);
		g.tys = [Ty.Int32];
		g.exprMax = 4;
		g.costCap = 0 as int64;
		const f = g.lambda([Ty.Int32], Ty.Int32, 0, FN_COST_CAP);
		if (f.cost > (0 as int64)) { shaped = true; }
		assert g.cost == (0 as int64) && g.costCap == (0 as int64) && g.mult == (1 as int64);
	}
	assert shaped;
}
