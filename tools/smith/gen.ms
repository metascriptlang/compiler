import { Rng, seeded } from "./rng";
import { ALL_TYS, ALL_FAMS, Fam, Features, Plant, Ty, W, W_DEFAULTS, famName, tyName, format } from "./features";

const FN_COST_CAP: int64 = 20000 as int64;
const ROUTINE_FRAMES: int32 = 4;
const TOP_COST_CAP: int64 = 200000 as int64;
const GEN_NODE_CAP: int32 = 4096;
const SEQ_LEN_CAP: int32 = 512;

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
	StructVar,
	ClassVar,
	ArrayVar,
	FixedVar,
	MapVar,
	SetVar,
	StrVar,
	OwnVar,
	HeldVar,
	IterFn,
	TupleVar,
	TupleFrozen,
	VecVar,
	CellVar,
	NestVar,
	PairVar,
	StackVar,
	ItemVar,
	EnumVar,
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

function trapsOnOverflow(t: Ty): boolean { return isSigned(t); }

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
const STR_CHARS: string[] = ["a", "b", "Z", " ", "é", "ÿ", "中", "-", "0", "\\n", "\\t", "\\\"", "\\\\"];
const STR_TESTS: string[] = [" == ", " != ", " < ", " > ", ".includes(", ".startsWith(", ".endsWith("];

enum EShape {
	Numeric,
	Match,
	Bitset,
	Alias,
	Distinct,
	Literal,
	Disc,
	Unknown,
	Never,
}

const E_SHAPES: EShape[] = [
	EShape.Numeric,
	EShape.Match,
	EShape.Bitset,
	EShape.Alias,
	EShape.Distinct,
	EShape.Literal,
	EShape.Disc,
	EShape.Unknown,
	EShape.Never,
];

struct ETy {
	id: int32;
	shape: EShape;
	name: string;
	ann: string;
	n: int32;
	lits: string[];
}

const FLAG_COUNTS: int32[] = [3, 8, 9, 17, 33, 65];
const LIT_SETS: string[] = ["n,e,s,w", "red,green,blue", "on,off", "lo,mid,hi,max"];
const BIT_OPS: string[] = ["&", "|", "^"];

function quoted(s: string): string { return "\"" + s + "\""; }

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
	w: int32[] = W_DEFAULTS;
	bodyDepth: int32 = 0;
	famShape: Shape = Shape.Other;
	elseArms: int32 = 0;
	atTop: boolean = false;
	arithInElse: int32 = 0;
	blockId: int32 = 0;
	blockCount: int32 = 0;
	directives: string[] = [];
	eTypes: ETy[] = [];

	wt(k: W): int32 { return this.w[k as int32]; }

	pickW(first: W, last: W): int32 {
		const from = first as int32;
		let total = 0;
		for (let i = from; i <= (last as int32); i++) { total += this.w[i]; }
		let k = this.rng.below(total);
		for (let i = from; i <= (last as int32); i++) {
			if (k < this.w[i]) { return i - from; }
			k -= this.w[i];
		}
		unreachable;
	}

	famTotal(): int32 {
		let total = 0;
		for (const f of this.fams) { total += this.w[(W.FamClosure as int32) + (f as int32)]; }
		return total;
	}

	pickFam(): Fam {
		let k = this.rng.below(this.famTotal());
		for (const f of this.fams) {
			const n = this.w[(W.FamClosure as int32) + (f as int32)];
			if (k < n) { return f; }
			k -= n;
		}
		unreachable;
	}

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
		const inElse = this.elseArms > 0;
		if (inElse) { this.arithInElse++; }
		const a = this.expr(t, depth + 1);
		const b = this.expr(t, depth + 1);
		if (inElse) { this.arithInElse--; }
		if (isFloat(t)) { return "(" + a + " " + this.pickOp(FLOAT_OPS) + " " + b + ")"; }
		const op = this.pickOp(INT_OPS);
		const guarded = op == "/" || op == "%" || (trapsOnOverflow(t) && (op == "+" || op == "-" || op == "*"));
		if (guarded) { return this.arithHelper(op, t) + "(" + a + ", " + b + ")"; }
		return "(" + a + " " + op + " " + b + ")";
	}

	binaryOrLeaf(t: Ty, depth: int32): string {
		return this.wt(W.ExprBinary) > 0 ? this.binary(t, depth) : this.leaf(t);
	}

	unary(t: Ty, depth: int32): string {
		const a = this.expr(t, depth + 1);
		if (isFloat(t)) { return "(-" + a + ")"; }
		if (!isSigned(t) || this.rng.chance(40)) { return "(~" + a + ")"; }
		return this.negHelper(t) + "(" + a + ")";
	}

	convert(t: Ty, depth: int32): string {
		if (this.tys.length < 2) { return this.binaryOrLeaf(t, depth); }
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
		if (this.fams.length > 0 && this.rng.chance(this.wt(W.ExprFam))) {
			this.famShape = Shape.Other;
			const fam = this.famExpr(t, depth);
			if (fam != "" && !(this.famShape == Shape.Ternary && this.arithInElse > 0)) {
				this.shape = this.famShape;
				return fam;
			}
		}
		const kind = this.pickW(W.ExprLeaf, W.ExprCall);
		if (kind == 0) { return this.leaf(t); }
		let out = "";
		let shape = Shape.Other;
		if (kind == 1) {
			out = this.binary(t, depth);
		} else if (kind == 2) {
			out = this.unary(t, depth);
		} else if (kind == 3) {
			out = this.convert(t, depth);
		} else if (kind == 4) {
			if (this.arithInElse > 0) { return this.leaf(t); }
			out = "(" + this.cond(depth + 1) + " ? " + this.expr(t, depth + 1) + " : " + this.elseExpr(t, depth) + ")";
			shape = Shape.Ternary;
		} else {
			const c = this.call(t, depth);
			if (c == "" && this.wt(W.ExprBinary) == 0) { return this.leaf(t); }
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

	entsAny(kind: EntKind): Ent[] {
		const out: Ent[] = [];
		for (const e of this.ents) { if (e.kind == kind) { out.push(e); } }
		return out;
	}

	pickEnt(ents: Ent[]): Ent { return ents[this.rng.below(ents.length)]; }

	elseExpr(t: Ty, depth: int32): string {
		this.elseArms++;
		const e = this.expr(t, depth + 1);
		this.elseArms--;
		return e;
	}

	ternary(text: string): string {
		this.famShape = Shape.Ternary;
		return text;
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
		this.bodyDepth++;
		const text = this.expr(t, depth);
		this.bodyDepth--;
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
		if (this.famTotal() == 0) { return ""; }
		const fam = this.pickFam();
		if (fam == Fam.Closure) { return this.closureExpr(t, depth); }
		if (fam == Fam.Union) { return this.unionExpr(t, depth); }
		if (fam == Fam.Agg) { return this.aggExpr(t, depth); }
		if (fam == Fam.Coll) { return this.collExpr(t, depth); }
		if (fam == Fam.Str) { return this.strExpr(t, depth); }
		if (fam == Fam.Own) { return this.ownExpr(t, depth); }
		if (fam == Fam.Iter) { return this.iterExpr(t, depth); }
		if (fam == Fam.Seq) { return this.seqExpr(t, depth); }
		if (fam == Fam.Gcls) { return this.gclsExpr(t, depth); }
		if (fam == Fam.Enum) { return this.enumExpr(t, depth); }
		return this.genericExpr(t, depth);
	}

	closureExpr(t: Ty, depth: int32): string {
		const k = this.pickW(W.ClosureNamed, W.ClosureIife);
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
		if (this.wt(W.ClosureIife) == 0) { return ""; }
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
		if (t == Ty.Int32 && this.rng.chance(this.wt(W.UnionLen))) {
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
		const k = this.pickW(W.GenericId, W.GenericBox);
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

	aggHelpers(t: Ty): string {
		const T = tyName(t);
		const X = tyTitle(t);
		this.useHelper("InS" + X, "struct InS" + X + " { c: " + T + "; d: " + T + "; }\n" +
			"struct PtS" + X + " { a: " + T + "; n: InS" + X + "; }\n" +
			"function mkS" + X + "(a: " + T + ", c: " + T + ", d: " + T + "): PtS" + X + " { return { a: a, n: { c: c, d: d } }; }\n" +
			"function setS" + X + "(ref s: PtS" + X + ", x: " + T + "): void { s.n.d = s.a; s.a = x; }\n" +
			"function eqS" + X + "(s: PtS" + X + ", r: PtS" + X + ", x: " + T + ", y: " + T + "): " + T + " { return s == r ? x : y; }\n" +
			"class CellC" + X + " {\n" +
			"\tv: " + T + ";\n" +
			"\tp: PtS" + X + ";\n" +
			"\tconstructor(v: " + T + ") { this.v = v; this.p = mkS" + X + "(v, v, v); }\n" +
			"\tget(): " + T + " { return this.v; }\n" +
			"\tput(x: " + T + "): CellC" + X + " { this.p.n.c = this.v; this.v = x; return this; }\n" +
			"}\n");
		return X;
	}

	structField(): string { return [".a", ".n.c", ".n.d"][this.rng.below(3)]; }

	structValue(t: Ty, depth: int32): string {
		const vars = this.entsOf(EntKind.StructVar, t);
		if (vars.length > 0 && this.rng.chance(70)) { return vars[this.rng.below(vars.length)].name; }
		return "mkS" + tyTitle(t) + "(" + this.expr(t, depth + 1) + ", " + this.expr(t, depth + 1) + ", " + this.expr(t, depth + 1) + ")";
	}

	aggExpr(t: Ty, depth: int32): string {
		const X = this.aggHelpers(t);
		const structs = this.entsOf(EntKind.StructVar, t);
		const cells = this.entsOf(EntKind.ClassVar, t);
		const k = this.pickW(W.AggField, W.AggEq);
		if (k == 0) {
			if (structs.length > 0 && (cells.length == 0 || this.rng.chance(50))) {
				return structs[this.rng.below(structs.length)].name + this.structField();
			}
			if (cells.length > 0) {
				return cells[this.rng.below(cells.length)].name + (this.rng.chance(50) ? ".v" : ".p" + this.structField());
			}
		}
		if (k == 1) {
			const cell = cells.length > 0 ? cells[this.rng.below(cells.length)].name : "new CellC" + X + "(" + this.expr(t, depth + 1) + ")";
			if (this.rng.chance(50)) { return cell + ".get()"; }
			return cell + ".put(" + this.expr(t, depth + 1) + ").p" + this.structField();
		}
		if (k == 3 && !isFloat(t)) {
			return "eqS" + X + "(" + this.structValue(t, depth) + ", " + this.structValue(t, depth) + ", " + this.expr(t, depth + 1) + ", " + this.expr(t, depth + 1) + ")";
		}
		return this.structValue(t, depth) + this.structField();
	}

	aggStatement(t: Ty, indent: string): string {
		const X = this.aggHelpers(t);
		const structs = this.entsOf(EntKind.StructVar, t);
		const cells = this.entsOf(EntKind.ClassVar, t);
		const k = this.pickW(W.AggStruct, W.AggPoke);
		if (k >= 1 && k <= 3 && structs.length > 0) {
			const s = structs[this.rng.below(structs.length)].name;
			const other = structs[this.rng.below(structs.length)].name;
			if (k == 1) {
				const form = this.rng.below(3);
				if (form == 0) { return indent + s + " = " + other + ";\n"; }
				const name = this.entName("s");
				const value = form == 1 ? other : "{ ..." + other + ", a: " + this.expr(t, 0) + " }";
				this.ents.push({ kind: EntKind.StructVar, name: name, ty: t, params: [], len: 0, cost: 0 as int64 });
				return indent + "let " + name + ": PtS" + X + " = " + value + ";\n";
			}
			if (k == 2) {
				if (this.rng.chance(25)) { return indent + s + ".n = " + other + ".n;\n"; }
				return indent + s + this.structField() + " = " + this.expr(t, 0) + ";\n";
			}
			return indent + "setS" + X + "(" + s + ", " + this.expr(t, 0) + ");\n";
		}
		if (k >= 5 && cells.length > 0) {
			const c = cells[this.rng.below(cells.length)].name;
			if (k == 5) {
				const name = this.entName("k");
				this.ents.push({ kind: EntKind.ClassVar, name: name, ty: t, params: [], len: 0, cost: 0 as int64 });
				return indent + "const " + name + " = " + c + ";\n";
			}
			const form = this.rng.below(4);
			if (form == 0) { return indent + c + ".v = " + this.expr(t, 0) + ";\n"; }
			if (form == 1) { return indent + c + ".p" + this.structField() + " = " + this.expr(t, 0) + ";\n"; }
			if (form == 2) { return indent + c + ".p = " + this.structValue(t, 0) + ";\n"; }
			return indent + c + ".put(" + this.expr(t, 0) + ");\n";
		}
		if (k >= 4) {
			const name = this.entName("k");
			const text = indent + "const " + name + " = new CellC" + X + "(" + this.expr(t, 0) + ");\n";
			this.ents.push({ kind: EntKind.ClassVar, name: name, ty: t, params: [], len: 0, cost: 0 as int64 });
			return text;
		}
		const name = this.entName("s");
		const text = indent + "let " + name + ": PtS" + X + " = mkS" + X + "(" + this.expr(t, 0) + ", " + this.expr(t, 0) + ", " + this.expr(t, 0) + ");\n";
		this.ents.push({ kind: EntKind.StructVar, name: name, ty: t, params: [], len: 0, cost: 0 as int64 });
		return text;
	}

	collHelpers(t: Ty): string {
		const T = tyName(t);
		const X = tyTitle(t);
		this.useHelper("ixI", "function ixI(i: int32, n: int32): int32 { const r = i % n; return r < 0 ? r + n : r; }\n");
		this.useHelper("pushA" + X, "function pushA" + X + "(xs: " + T + "[], x: " + T + "): " + T + "[] { xs.push(x); return xs; }\n" +
			"function restA" + X + "(d: " + T + ", ...xs: " + T + "[]): " + T + " { return xs.length > 0 ? xs[xs.length - 1] : d; }\n");
		return X;
	}

	items(t: Ty, depth: int32, n: int32): string {
		let out = "";
		for (let i = 0; i < n; i++) {
			const e = this.expr(t, depth + 1);
			out = out == "" ? e : out + ", " + e;
		}
		return out;
	}

	collSize(t: Ty, depth: int32): string {
		if (t == Ty.Int32) {
			const arrays = this.entsAny(EntKind.ArrayVar);
			if (arrays.length == 0) { return ""; }
			const a = this.pickEnt(arrays);
			const form = this.rng.below(4);
			if (form == 1 && !isFloat(a.ty)) { return "(" + a.name + ".indexOf(" + this.expr(a.ty, depth + 1) + ") as int32)"; }
			if (form == 2) { return a.name + ".join(\",\").length"; }
			if (form == 3) { return a.name + ".concat(" + this.pickEnt(this.entsOf(EntKind.ArrayVar, a.ty)).name + ").length"; }
			return a.name + ".length";
		}
		if (isFloat(t)) { return ""; }
		const owners = this.entsOf(EntKind.ArrayVar, t).concat(this.entsOf(EntKind.SetVar, t));
		if (owners.length == 0) { return ""; }
		const o = this.pickEnt(owners);
		const test = o.kind == EntKind.SetVar ? ".has(" : ".includes(";
		const text = "(" + o.name + test + this.expr(t, depth + 1) + ") ? " + this.expr(t, depth + 1) + " : " + this.elseExpr(t, depth) + ")";
		return this.ternary(text);
	}

	collExpr(t: Ty, depth: int32): string {
		const X = this.collHelpers(t);
		const arrays = this.entsOf(EntKind.ArrayVar, t);
		const k = this.pickW(W.CollIndex, W.CollRest);
		if (k == 1) {
			const size = this.collSize(t, depth);
			if (size != "") { return size; }
		}
		if (k == 2) {
			const maps = this.entsOf(EntKind.MapVar, t);
			if (maps.length > 0) {
				const text = "(" + this.pickEnt(maps).name + ".get(" + this.smallInt(depth) + ") ?? " + this.elseExpr(t, depth) + ")";
				return this.ternary(text);
			}
		}
		if (k == 3) {
			const fixed = this.entsOf(EntKind.FixedVar, t);
			if (fixed.length > 0) {
				const f = this.pickEnt(fixed);
				return f.name + "[" + String(this.rng.below(f.len)) + "]";
			}
		}
		if (k == 4) {
			const d = this.expr(t, depth + 1);
			if (arrays.length > 0 && this.rng.chance(60)) { return "restA" + X + "(" + d + ", ..." + this.pickEnt(arrays).name + ")"; }
			const rest = this.items(t, depth, this.rng.below(3));
			return "restA" + X + "(" + d + (rest == "" ? "" : ", " + rest) + ")";
		}
		if (arrays.length > 0 && this.rng.chance(70)) {
			const a = this.pickEnt(arrays).name;
			const text = "(" + a + ".length > 0 ? " + a + "[ixI(" + this.smallInt(depth) + ", " + a + ".length)] : " + this.elseExpr(t, depth) + ")";
			return this.ternary(text);
		}
		const n = this.rng.between(1, 3);
		return "[" + this.items(t, depth, n) + "][" + String(this.rng.below(n)) + "]";
	}

	collLoop(t: Ty, a: string, indent: string): string {
		const trips = this.rng.between(1, 4);
		if (!this.reserve((2 * trips) as int64)) { return ""; }
		const init = this.expr(t, 0);
		const acc = this.newLocal(t);
		const j = this.entName("j");
		const maps = this.entsOf(EntKind.MapVar, t);
		const form = this.rng.below(maps.length > 0 ? 3 : 2);
		const saved = this.scope.length;
		const savedMult = this.mult;
		this.mult = this.mult * (trips as int64);
		let head = "";
		if (form == 1) {
			this.scope.push({ name: j, ty: Ty.Int32, writable: false });
			this.scope.push({ name: a + "[" + j + "]", ty: t, writable: false });
			head = "for (let " + j + ": int32 = 0; " + j + " < " + a + ".length && " + j + " < " + String(trips) + "; " + j + "++) {\n";
		} else if (form == 2) {
			const key = this.entName("x");
			const value = this.entName("x");
			this.scope.push({ name: key, ty: Ty.Int32, writable: false });
			this.scope.push({ name: value, ty: t, writable: false });
			head = "for (const [" + key + ", " + value + "] of " + this.pickEnt(maps).name + ") {\n";
		} else {
			const x = this.entName("x");
			this.scope.push({ name: x, ty: t, writable: false });
			head = "for (const " + x + " of " + a + ") {\n";
		}
		const body = this.expr(t, 1);
		this.mult = savedMult;
		while (this.scope.length > saved) { this.scope.pop(); }
		const tail = form == 1 ? "" : indent + "\t" + j + "++;\n" + indent + "\tif (" + j + " >= " + String(trips) + ") { break; }\n";
		return indent + "let " + acc + ": " + tyName(t) + " = " + init + ";\n" +
			(form == 1 ? "" : indent + "let " + j + ": int32 = 0;\n") +
			indent + head +
			indent + "\t" + acc + " = " + body + ";\n" +
			tail + indent + "}\n";
	}

	collStatement(t: Ty, indent: string): string {
		const X = this.collHelpers(t);
		const T = tyName(t);
		const arrays = this.entsOf(EntKind.ArrayVar, t);
		const k = this.pickW(W.CollDecl, W.CollFixed);
		if (k >= 1 && k <= 5 && arrays.length > 0) {
			const a = this.pickEnt(arrays).name;
			if (k == 1) {
				const value = this.rng.chance(50) ? a : "pushA" + X + "(" + a + ", " + this.expr(t, 0) + ")";
				const name = this.entName("a");
				this.ents.push({ kind: EntKind.ArrayVar, name: name, ty: t, params: [], len: 0, cost: 0 as int64 });
				return indent + "const " + name + " = " + value + ";\n";
			}
			if (k == 2) { return indent + a + ".push(" + this.expr(t, 0) + ");\n"; }
			if (k == 3) {
				const form = this.rng.below(6);
				const guard = indent + "if (" + a + ".length > 0) { ";
				if (form == 0) { return guard + a + "[ixI(" + this.smallInt(0) + ", " + a + ".length)] = " + this.expr(t, 0) + "; }\n"; }
				if (form == 1) { return guard + a + ".pop(); }\n"; }
				if (form == 2) { return guard + a + ".splice(ixI(" + this.smallInt(0) + ", " + a + ".length), 1); }\n"; }
				if (form == 3) {
					const n = String(this.rng.below(4));
					return indent + "if (" + a + ".length > " + n + ") { " + a + ".setLength(" + n + "); }\n";
				}
				if (form == 4) { return indent + a + ".fill(" + this.expr(t, 0) + ");\n"; }
				return indent + a + ".reverse();\n";
			}
			if (k == 4) { return this.collLoop(t, a, indent); }
			const n = this.rng.between(1, 3);
			let pattern = "";
			for (let i = 0; i < n; i++) {
				const slot = "l" + String(this.localCount + i) + " = " + this.expr(t, 0);
				pattern = pattern == "" ? slot : pattern + ", " + slot;
			}
			for (let i = 0; i < n; i++) { this.newLocal(t); }
			if (this.rng.chance(50)) { pattern += ", ..." + this.entName("r"); }
			return indent + "let [" + pattern + "] = " + a + ";\n";
		}
		if (k == 6) {
			const keyed = this.entsOf(EntKind.MapVar, t).concat(this.entsOf(EntKind.SetVar, t));
			if (keyed.length > 0 && this.rng.chance(60)) {
				const o = this.pickEnt(keyed);
				const drop = this.rng.chance(30);
				if (o.kind == EntKind.SetVar) { return indent + o.name + (drop ? ".delete(" : ".add(") + this.expr(t, 0) + ");\n"; }
				if (drop) { return indent + o.name + ".delete(" + this.smallInt(0) + ");\n"; }
				return indent + o.name + ".set(" + this.smallInt(0) + ", " + this.expr(t, 0) + ");\n";
			}
			if (isFloat(t) || this.rng.chance(50)) {
				const name = this.entName("m");
				const text = indent + "const " + name + " = new Map<int32, " + T + ">();\n" +
					indent + name + ".set(" + this.smallInt(0) + ", " + this.expr(t, 0) + ");\n";
				this.ents.push({ kind: EntKind.MapVar, name: name, ty: t, params: [], len: 0, cost: 0 as int64 });
				return text;
			}
			const name = this.entName("m");
			const text = indent + "const " + name + " = new Set<" + T + ">();\n" +
				indent + name + ".add(" + this.expr(t, 0) + ");\n";
			this.ents.push({ kind: EntKind.SetVar, name: name, ty: t, params: [], len: 0, cost: 0 as int64 });
			return text;
		}
		if (k == 7) {
			const fixed = this.entsOf(EntKind.FixedVar, t);
			if (fixed.length > 0 && this.rng.chance(60)) {
				const f = this.pickEnt(fixed);
				if (this.rng.chance(50)) { return indent + f.name + "[" + String(this.rng.below(f.len)) + "] = " + this.expr(t, 0) + ";\n"; }
				const name = this.entName("w");
				this.ents.push({ kind: EntKind.FixedVar, name: name, ty: t, params: [], len: f.len, cost: 0 as int64 });
				return indent + "let " + name + ": " + T + "[" + String(f.len) + "] = " + f.name + ";\n";
			}
			const n = this.rng.between(1, 4);
			const value = this.items(t, -1, n);
			const name = this.entName("w");
			this.ents.push({ kind: EntKind.FixedVar, name: name, ty: t, params: [], len: n, cost: 0 as int64 });
			return indent + "let " + name + ": " + T + "[" + String(n) + "] = [" + value + "];\n";
		}
		let value = "";
		const form = arrays.length > 0 ? this.rng.below(5) : 0;
		if (form == 1) {
			value = "[..." + this.pickEnt(arrays).name + ", " + this.expr(t, 0) + "]";
		} else if (form == 2) {
			value = this.pickEnt(arrays).name + ".concat(" + this.pickEnt(arrays).name + ")";
		} else if (form == 3) {
			const from = this.rng.below(3);
			value = this.pickEnt(arrays).name + ".slice(" + String(from) + (this.rng.chance(50) ? ", " + String(from + this.rng.below(4)) : "") + ")";
		} else if (form == 4) {
			const a = this.pickEnt(arrays).name;
			const trips = this.rng.between(1, 4);
			const f = this.lambda([t], t, 0, this.spare(trips as int64));
			if (!this.reserve((trips as int64) * f.cost)) { return ""; }
			value = a + ".slice(0, " + String(trips) + ").map(" + f.text + ")";
		} else {
			value = "[" + this.items(t, -1, this.rng.below(4)) + "]";
		}
		const name = this.entName("a");
		this.ents.push({ kind: EntKind.ArrayVar, name: name, ty: t, params: [], len: 0, cost: 0 as int64 });
		return indent + "let " + name + ": " + T + "[] = " + value + ";\n";
	}

	strLiteral(min: int32): string {
		let out = "";
		const n = this.rng.between(min, 4);
		for (let i = 0; i < n; i++) { out += STR_CHARS[this.rng.below(STR_CHARS.length)]; }
		return out;
	}

	strLeaf(): string {
		const vars = this.entsAny(EntKind.StrVar);
		if (vars.length > 0 && this.rng.chance(60)) { return this.pickEnt(vars).name; }
		return "\"" + this.strLiteral(0) + "\"";
	}

	strText(depth: int32): string {
		if (this.nodesLeft == 0 || depth >= this.exprMax || !this.reserve(1 as int64)) { return this.strLeaf(); }
		this.nodesLeft--;
		const k = this.pickW(W.StrConcat, W.StrEdit);
		if (k == 0) { return "(" + this.strText(depth + 1) + " + " + this.strText(depth + 1) + ")"; }
		if (k == 1) {
			const t = this.pickTy();
			if (this.rng.chance(50)) { return "String(" + this.expr(t, depth + 1) + ")"; }
			return "`" + this.strLiteral(0) + "${" + this.expr(t, depth + 1) + "}" + this.strLiteral(0) + "${" + this.strText(depth + 1) + "}`";
		}
		const s = "(" + this.strText(depth + 1) + ")";
		if (k == 2) {
			const form = this.rng.below(4);
			const from = String(this.rng.below(5));
			const to = String(this.rng.below(7));
			if (form == 0) { return s + ".slice(" + from + (this.rng.chance(50) ? ", " + to : "") + ")"; }
			if (form == 1) { return s + ".substring(" + from + ", " + to + ")"; }
			if (form == 2) { return s + ".charAt(" + String(this.rng.below(6)) + ")"; }
			this.useHelper("ixI", "function ixI(i: int32, n: int32): int32 { const r = i % n; return r < 0 ? r + n : r; }\n");
			const at = this.useHelper("atS", "function atS(s: string, i: int32): string { return s.length > 0 ? s[ixI(i, s.length)] : \"\"; }\n");
			return at + "(" + s + ", " + this.smallInt(depth) + ")";
		}
		if (k == 3) { return s + [".toUpperCase()", ".toLowerCase()", ".trim()", ".trimStart()", ".trimEnd()"][this.rng.below(5)]; }
		if (k == 4) {
			const form = this.rng.below(3);
			if (form == 0) { return s + ".repeat(" + String(this.rng.below(3)) + ")"; }
			const filled = "(" + s + " + \"" + this.strLiteral(1) + "\")";
			return filled + (form == 1 ? ".padStart(" : ".padEnd(") + String(this.rng.below(9)) + ", \"" + this.strLiteral(1) + "\")";
		}
		const form = this.rng.below(3);
		const search = "\"" + this.strLiteral(1) + "\"";
		if (form == 0) { return s + ".replace(" + search + ", \"" + this.strLiteral(0) + "\")"; }
		if (form == 1) { return s + ".replaceAll(" + search + ", \"" + this.strLiteral(0) + "\")"; }
		return s + ".split(" + search + ").join(\"" + this.strLiteral(0) + "\")";
	}

	strExpr(t: Ty, depth: int32): string {
		const k = this.pickW(W.StrSize, W.StrTest);
		if (t == Ty.Int32 && k == 0) {
			const s = "(" + this.strText(depth + 1) + ")";
			const form = this.rng.below(4);
			if (form == 0) { return s + ".length"; }
			if (form == 3) { return s + ".split(\"" + this.strLiteral(1) + "\").length"; }
			return "(" + s + (form == 1 ? ".indexOf(\"" : ".lastIndexOf(\"") + this.strLiteral(1) + "\") as int32)";
		}
		if (t == Ty.Int32 && k == 1) {
			this.useHelper("ixI", "function ixI(i: int32, n: int32): int32 { const r = i % n; return r < 0 ? r + n : r; }\n");
			const code = this.useHelper("codeS", "function codeS(s: string, i: int32): int32 { return s.length > 0 ? (s.charCodeAt(ixI(i, s.length)) as int32) : -1; }\n");
			return code + "(" + this.strText(depth + 1) + ", " + this.smallInt(depth) + ")";
		}
		const test = STR_TESTS[this.rng.below(STR_TESTS.length)];
		const left = this.strText(depth + 1);
		const a = left.startsWith("\"") ? "(" + left + " as string)" : left;
		const b = this.strText(depth + 1);
		const c = test.startsWith(".") ? "(" + a + ")" + test + b + ")" : "(" + a + test + b + ")";
		const text = "(" + c + " ? " + this.expr(t, depth + 1) + " : " + this.elseExpr(t, depth) + ")";
		return this.ternary(text);
	}

	strStatement(indent: string): string {
		const vars = this.entsAny(EntKind.StrVar);
		const k = this.pickW(W.StrDecl, W.StrAssign);
		if (k > 0 && vars.length > 0) {
			const v = this.pickEnt(vars).name;
			if (k == 1) { return indent + v + " += (" + this.strText(0) + ").slice(0, 8);\n"; }
			return indent + v + " = (" + this.strText(0) + ").slice(0, 32);\n";
		}
		const value = this.strText(0);
		const name = this.entName("s");
		this.ents.push({ kind: EntKind.StrVar, name: name, ty: Ty.Int32, params: [], len: 0, cost: 0 as int64 });
		return indent + "let " + name + ": string = " + value + ";\n";
	}

	ownHelpers(t: Ty): string {
		const T = tyName(t);
		const X = tyTitle(t);
		const O = "Own" + X;
		this.useHelper("ownHooks", "let ownHooks: int32 = 0;\n");
		this.useHelper("ixI", "function ixI(i: int32, n: int32): int32 { const r = i % n; return r < 0 ? r + n : r; }\n");
		this.useHelper(O, "struct " + O + " { v: " + T + "; tag: string; }\n" +
			"function onDestroy(this o: " + O + "): void { ownHooks = (ownHooks + 1) % 1000; }\n" +
			"function onCopy(this ref d: " + O + ", s: " + O + "): void { ownHooks = (ownHooks + 1) % 1000; d.v = s.v; d.tag = s.tag; }\n" +
			"function mkO" + X + "(v: " + T + ", t: string): " + O + " { return { v: v, tag: t }; }\n" +
			"function takeO" + X + "(o: " + O + "): " + T + " { return o.v; }\n" +
			"function bumpO" + X + "(ref o: " + O + ", x: " + T + "): void { o.v = x; o.tag = o.tag.slice(0, 4) + \"+\"; }\n" +
			"function fillO" + X + "(out o: " + O + ", x: " + T + "): void { o = mkO" + X + "(x, \"o\"); }\n");
		return X;
	}

	ownExpr(t: Ty, depth: int32): string {
		if (this.bodyDepth > 0) { return ""; }
		const owns = this.entsOf(EntKind.OwnVar, t);
		const held = this.entsOf(EntKind.HeldVar, t);
		const k = this.pickW(W.OwnField, W.OwnHeld);
		if (k == 1 && held.length > 0) {
			const h = this.pickEnt(held).name;
			const text = "(" + h + ".length > 0 ? " + h + "[ixI(" + this.smallInt(depth) + ", " + h + ".length)].v : " + this.elseExpr(t, depth) + ")";
			return this.ternary(text);
		}
		if (owns.length == 0) { return ""; }
		const o = this.pickEnt(owns).name;
		return t == Ty.Int32 && this.rng.chance(30) ? o + ".tag.length" : o + ".v";
	}

	dropEnt(name: string): void {
		for (let i = 0; i < this.ents.length; i++) {
			if (this.ents[i].name == name) {
				this.ents.splice(i, 1);
				return;
			}
		}
	}

	ownStatement(t: Ty, indent: string): string {
		const X = this.ownHelpers(t);
		const O = "Own" + X;
		const owns = this.entsOf(EntKind.OwnVar, t);
		const held = this.entsOf(EntKind.HeldVar, t);
		const k = this.pickW(W.OwnDecl, W.OwnSink);
		if (k >= 1 && owns.length > 0) {
			const o = this.pickEnt(owns).name;
			if (k == 1) {
				const other = this.pickEnt(owns).name;
				if (other != o && this.rng.chance(50)) { return indent + o + " = " + other + ";\n"; }
				const name = this.entName("o");
				this.ents.push({ kind: EntKind.OwnVar, name: name, ty: t, params: [], len: this.blockId, cost: 0 as int64 });
				return indent + "let " + name + ": " + O + " = " + o + ";\n";
			}
			if (k == 2) {
				const movable: Ent[] = [];
				for (const e of owns) { if (e.len == this.blockId) { movable.push(e); } }
				if (movable.length > 0) {
					const m = this.pickEnt(movable).name;
					this.dropEnt(m);
					const form = this.rng.below(held.length > 0 ? 3 : 2);
					if (form == 2) { return indent + this.pickEnt(held).name + ".push(move " + m + ");\n"; }
					if (form == 1) { return indent + "let " + this.newLocal(t) + ": " + tyName(t) + " = takeO" + X + "(move " + m + ");\n"; }
					const name = this.entName("o");
					this.ents.push({ kind: EntKind.OwnVar, name: name, ty: t, params: [], len: this.blockId, cost: 0 as int64 });
					return indent + "let " + name + ": " + O + " = move " + m + ";\n";
				}
			}
			if (k == 3) { return indent + "bumpO" + X + "(" + o + ", " + this.expr(t, 0) + ");\n"; }
			if (k == 4) { return indent + "fillO" + X + "(out " + o + ", " + this.expr(t, 0) + ");\n"; }
			if (k == 5) {
				if (held.length > 0 && this.rng.chance(50)) { return indent + this.pickEnt(held).name + ".push(" + o + ");\n"; }
				const value = "[" + o + ", mkO" + X + "(" + this.expr(t, 0) + ", \"h\")]";
				const name = this.entName("h");
				this.ents.push({ kind: EntKind.HeldVar, name: name, ty: t, params: [], len: 0, cost: 0 as int64 });
				return indent + "let " + name + ": " + O + "[] = " + value + ";\n";
			}
		}
		const value = "mkO" + X + "(" + this.expr(t, 0) + ", \"" + this.strLiteral(0) + "\")";
		const name = this.entName("o");
		this.ents.push({ kind: EntKind.OwnVar, name: name, ty: t, params: [], len: this.blockId, cost: 0 as int64 });
		return indent + "let " + name + ": " + O + " = " + value + ";\n";
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

	famStatement(indent: string, depth: int32): string {
		if (this.famTotal() == 0) { return ""; }
		const fam = this.pickFam();
		const t = this.pickTy();
		const T = tyName(t);
		if (fam == Fam.Closure) {
			const k = this.pickW(W.ClosureDecl, W.ClosureRoutine);
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
			if (k == 5) { return this.routineDecl(t, indent); }
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
		if (fam == Fam.Agg) { return this.aggStatement(t, indent); }
		if (fam == Fam.Coll) { return this.collStatement(t, indent); }
		if (fam == Fam.Str) { return this.strStatement(indent); }
		if (fam == Fam.Own) { return this.ownStatement(t, indent); }
		if (fam == Fam.Iter) { return this.iterStatement(t, indent, depth); }
		if (fam == Fam.Seq) { return this.seqStatement(t, indent); }
		if (fam == Fam.Gcls) { return this.gclsStatement(t, indent); }
		if (fam == Fam.Enum) { return this.enumStatement(t, indent, depth); }
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

	iterHelpers(): void {
		this.useHelper("nthI", "function nthI<T>(it: Iterator<T>, n: int32, d: T): T {\n" +
			"\tlet i: int32 = 0;\n" +
			"\tfor (const v of it) {\n" +
			"\t\tif (i == n) { return v; }\n" +
			"\t\ti++;\n" +
			"\t}\n" +
			"\treturn d;\n}\n");
		this.useHelper("lastI", "function lastI<T>(it: Iterator<T>, d: T): T {\n" +
			"\tlet r = d;\n" +
			"\tfor (const v of it) { r = v; }\n" +
			"\treturn r;\n}\n");
	}

	iterExpr(t: Ty, depth: int32): string {
		const gens = this.entsOf(EntKind.IterFn, t);
		if (gens.length == 0) { return ""; }
		const g = this.pickEnt(gens);
		if (!this.reserve(g.cost + (1 as int64))) { return ""; }
		this.iterHelpers();
		const call = g.name + "(" + this.smallInt(depth) + ")";
		if (this.pickW(W.IterNth, W.IterLast) == 0) {
			return "nthI(" + call + ", " + this.smallInt(depth) + ", " + this.expr(t, depth + 1) + ")";
		}
		return "lastI(" + call + ", " + this.expr(t, depth + 1) + ")";
	}

	iterStatement(t: Ty, indent: string, depth: int32): string {
		const gens = this.entsOf(EntKind.IterFn, t);
		const k = this.pickW(W.IterDecl, W.IterManual);
		if (k == 1 && gens.length > 0) { return this.iterDrain(t, gens, indent); }
		if (k == 2 && gens.length > 0) { return this.iterManual(t, gens, indent); }
		if (depth > 0 || this.atTop) { return ""; }
		return this.iterDecl(t, indent);
	}

	iterDecl(t: Ty, indent: string): string {
		const T = tyName(t);
		const name = this.entName("y");
		const q = this.entName("q");
		const acc = this.entName("a");
		const trips = this.rng.between(1, this.tripMax);
		const cap = FN_COST_CAP / ((4 * trips + 4) as int64);
		const u = this.pickTy();
		const outer = this.visible(u, true);
		const inner = this.entsAny(EntKind.IterFn);
		const saved = this.scope.length;
		const savedEnts = this.ents.length;
		this.scope.push({ name: q, ty: Ty.Int32, writable: false });
		const init = this.routine(t, 1, cap);
		this.scope.push({ name: acc, ty: t, writable: true });
		let pre = "";
		let cost = init.cost + (2 as int64);
		if (this.rng.chance(50)) {
			const c = this.entName("c");
			const d = this.entName("q");
			this.scope.push({ name: d, ty: t, writable: false });
			const body = this.routine(t, 1, cap);
			this.scope.pop();
			this.ents.push({ kind: EntKind.Callable, name: c, ty: t, params: [t], len: 0, cost: body.cost + (1 as int64) });
			pre = indent + "\tconst " + c + " = (" + d + ": " + T + "): " + T + " => { " + acc + " = " + body.text + "; return " + acc + "; };\n";
		}
		const i = "i" + String(this.loopCount);
		this.loopCount = this.loopCount + 1;
		this.scope.push({ name: i, ty: Ty.Int32, writable: false });
		const value = this.routine(t, 1, cap);
		let each = value.cost + (2 as int64);
		let body = indent + "\t\tyield " + value.text + ";\n";
		if (this.rng.chance(50)) {
			const step = this.routine(t, 1, cap);
			each = each + step.cost + (1 as int64);
			const line = indent + "\t\t" + acc + " = " + step.text + ";\n";
			body = this.rng.chance(50) ? line + body : body + line;
		}
		if (outer.length > 0 && this.rng.chance(50)) {
			const v = outer[this.rng.below(outer.length)];
			const write = this.routine(u, 1, cap);
			each = each + write.cost + (1 as int64);
			body += indent + "\t\t" + v.name + " = " + write.text + ";\n";
		}
		if (inner.length > 0 && this.rng.chance(50)) {
			const m = this.pickEnt(inner);
			const x = this.entName("x");
			this.scope.push({ name: x, ty: m.ty, writable: false });
			const fold = this.routine(t, 1, cap);
			this.scope.pop();
			const drain = m.cost + (m.len as int64) * (fold.cost + (1 as int64));
			if (drain <= cap * (4 as int64)) {
				each = each + drain;
				body += indent + "\t\tfor (const " + x + " of " + m.name + "(" + i + ")) { " + acc + " = " + fold.text + "; }\n";
			}
		}
		while (this.scope.length > saved) { this.scope.pop(); }
		while (this.ents.length > savedEnts) { this.ents.pop(); }
		cost = cost + (trips as int64) * each;
		this.ents.push({ kind: EntKind.IterFn, name: name, ty: t, params: [Ty.Int32], len: trips + 1, cost: cost });
		return indent + "function* " + name + "(" + q + ": int32): Iterator<" + T + "> {\n" +
			indent + "\tlet " + acc + ": " + T + " = " + init.text + ";\n" +
			pre +
			indent + "\tfor (let " + i + ": int32 = 0; " + i + " < " + q + " && " + i + " < " + String(trips) + "; " + i + "++) {\n" +
			body +
			indent + "\t}\n" +
			indent + "\tyield " + acc + ";\n" +
			indent + "}\n";
	}

	iterDrain(t: Ty, gens: Ent[], indent: string): string {
		const g = this.pickEnt(gens);
		if (!this.reserve(g.cost + (1 as int64))) { return ""; }
		const T = tyName(t);
		const arg = this.smallInt(0);
		const vars = this.visible(t, true);
		let head = "";
		let target = "";
		if (vars.length > 0 && this.rng.chance(50)) {
			target = vars[this.rng.below(vars.length)].name;
		} else {
			const init = this.expr(t, 0);
			target = this.newLocal(t);
			head = indent + "let " + target + ": " + T + " = " + init + ";\n";
		}
		const x = this.entName("x");
		const savedMult = this.mult;
		this.mult = this.mult * (g.len as int64);
		this.scope.push({ name: x, ty: t, writable: false });
		const value = this.expr(t, 1);
		const stop = this.rng.chance(50) ? indent + "\tif " + this.cond(1) + " { break; }\n" : "";
		this.scope.pop();
		this.mult = savedMult;
		return head + indent + "for (const " + x + " of " + g.name + "(" + arg + ")) {\n" +
			indent + "\t" + target + " = " + value + ";\n" +
			stop +
			indent + "}\n";
	}

	iterManual(t: Ty, gens: Ent[], indent: string): string {
		const a = this.pickEnt(gens);
		const b = this.pickEnt(gens);
		if (!this.reserve(a.cost + b.cost + (2 as int64))) { return ""; }
		const T = tyName(t);
		const ia = this.entName("t");
		const ib = this.entName("t");
		const ra = this.entName("r");
		const rb = this.entName("r");
		const head = indent + "const " + ia + " = " + a.name + "(" + this.smallInt(0) + ");\n" +
			indent + "const " + ib + " = " + b.name + "(" + this.smallInt(0) + ");\n";
		const init = this.expr(t, 0);
		const target = this.newLocal(t);
		const savedMult = this.mult;
		this.mult = this.mult * (a.len as int64);
		this.scope.push({ name: ra + ".value", ty: t, writable: false });
		const fa = this.expr(t, 1);
		this.scope.pop();
		this.mult = savedMult * (b.len as int64);
		this.scope.push({ name: rb + ".value", ty: t, writable: false });
		const fb = this.expr(t, 1);
		this.scope.pop();
		this.mult = savedMult;
		return head +
			indent + "let " + target + ": " + T + " = " + init + ";\n" +
			indent + "let " + ra + " = " + ia + ".next();\n" +
			indent + "let " + rb + " = " + ib + ".next();\n" +
			indent + "while (!" + ra + ".done || !" + rb + ".done) {\n" +
			indent + "\tif (!" + ra + ".done) { " + target + " = " + fa + "; " + ra + " = " + ia + ".next(); }\n" +
			indent + "\tif (!" + rb + ".done) { " + target + " = " + fb + "; " + rb + " = " + ib + ".next(); }\n" +
			indent + "}\n";
	}

	directive(line: string): void {
		for (const d of this.directives) { if (d == line) { return; } }
		this.directives.push(line);
	}

	pushEnt(kind: EntKind, name: string, t: Ty, params: Ty[], len: int32, cost: int64): void {
		this.ents.push({ kind: kind, name: name, ty: t, params: params, len: len, cost: cost });
	}

	liveAny(kind: EntKind): Ent[] {
		const out: Ent[] = [];
		if (this.bodyDepth > 0) { return out; }
		for (const e of this.ents) { if (e.kind == kind) { out.push(e); } }
		return out;
	}

	liveOf(kind: EntKind, t: Ty): Ent[] {
		const out: Ent[] = [];
		if (this.bodyDepth > 0) { return out; }
		for (const e of this.ents) { if (e.kind == kind && e.ty == t) { out.push(e); } }
		return out;
	}

	ixHelper(): string {
		return this.useHelper("ixI", "function ixI(i: int32, n: int32): int32 { const r = i % n; return r < 0 ? r + n : r; }\n");
	}

	kit(name: string): string {
		if (name == "swapQ") { return this.useHelper(name, "function swapQ<T>(ref a: T, ref b: T): void { const t = a; a = b; b = t; }\n"); }
		if (name == "fillQ") { return this.useHelper(name, "function fillQ<T>(out o: T, v: T): void { o = v; }\n"); }
		if (name == "takeQ") { return this.useHelper(name, "function takeQ<T>(x: T): T { return x; }\n"); }
		if (name == "roQ") { return this.useHelper(name, "function roQ<T>(readonly x: T): T { return x; }\n"); }
		if (name == "headQ") { return this.useHelper(name, "function headQ<T>(readonly v: Vec<T>, d: T): T { return v.length > 0 ? v[0] : d; }\n"); }
		if (name == "pushQ") { return this.useHelper(name, "function pushQ<T>(ref v: Vec<T>, x: T): void { v.push(x); }\n"); }
		if (name == "readG") { return this.useHelper(name, "function readG<T>(b: Borrow<T>, d: T): T { return b; }\n"); }
		if (name == "firstQ") { return this.useHelper(name, "function firstQ<A, B>(readonly t: [A, B]): A { return t[0]; }\n"); }
		if (name == "swapT") { return this.useHelper(name, "function swapT<A, B>(t: [A, B]): [B, A] { return [t[1], t[0]]; }\n"); }
		if (name == "pairT") { return this.useHelper(name, "function pairT<A, B>(a: A, b: B): [A, B] { return [a, b]; }\n"); }
		if (name == "idQ") { return this.useHelper(name, "function idQ<T>(x: T): T { return x; }\n"); }
		if (name == "ItemQ") {
			return this.useHelper(name, "interface KeyedQ { key: int32; }\n" +
				"class ItemQ<T> implements KeyedQ {\n" +
				"\tkey: int32;\n" +
				"\tv: T;\n" +
				"\tconstructor(k: int32, v: T) { this.key = k; this.v = v; }\n" +
				"}\n" +
				"function bestQ<T extends KeyedQ>(a: T, b: T): T { return a.key >= b.key ? a : b; }\n");
		}
		if (name == "PairQ") {
			return this.useHelper(name, "class PairQ<A, B> {\n" +
				"\ta: A;\n" +
				"\tb: B;\n" +
				"\tconstructor(a: A, b: B) { this.a = a; this.b = b; }\n" +
				"\tswap(): PairQ<B, A> { return new PairQ<B, A>(this.b, this.a); }\n" +
				"\tfirst(): A { return this.a; }\n" +
				"\tsecond(): B { return this.b; }\n" +
				"}\n");
		}
		if (name == "CellQ") {
			this.kit("PairQ");
			return this.useHelper(name, "class CellQ<T> {\n" +
				"\tv: T;\n" +
				"\tconstructor(v: T) { this.v = v; }\n" +
				"\tget(): T { return this.v; }\n" +
				"\tset(x: T): void { this.v = x; }\n" +
				"\tmap<U>(f: (x: T) => U): CellQ<U> { return new CellQ<U>(f(this.v)); }\n" +
				"\tpairWith<U>(u: U): PairQ<T, U> { return new PairQ<T, U>(this.v, u); }\n" +
				"}\n");
		}
		if (name == "StackQ") {
			return this.useHelper(name, "class StackQ<T> {\n" +
				"\titems: T[] = [];\n" +
				"\tpush(x: T): void { this.items.push(x); }\n" +
				"\tsize(): int32 { return this.items.length as int32; }\n" +
				"\ttop(d: T): T { return this.items.length > 0 ? this.items[this.items.length - 1] : d; }\n" +
				"\tdrop(): void { if (this.items.length > 0) { this.items.pop(); } }\n" +
				"}\n");
		}
		if (name == "WrapQ") {
			return this.useHelper(name, "struct WrapQ<T> { v: T; k: int32; }\n" +
				"interface HolderQ<T> { item: T; n: int32; }\n" +
				"function newWrapQ<T>(v: T, k: int32): WrapQ<T> { return { v: v, k: k }; }\n" +
				"function unwrapQ<T>(w: WrapQ<T>): T { return w.v; }\n" +
				"function holdQ<T>(x: T, n: int32): HolderQ<T> { return { item: x, n: n }; }\n");
		}
		unreachable;
	}

	spanHelpers(t: Ty): string {
		const T = tyName(t);
		const X = tyTitle(t);
		this.ixHelper();
		this.useHelper("spanAt" + X, "function spanAt" + X + "(s: Span<" + T + ">, i: int32, d: " + T + "): " + T + " { return s.length > 0 ? s[ixI(i, s.length as int32)] : d; }\n" +
			"function spanSet" + X + "(s: Span<" + T + ">, i: int32, x: " + T + "): void { if (s.length > 0) { s[ixI(i, s.length as int32)] = x; } }\n" +
			"function restV" + X + "(d: " + T + ", ...xs: " + T + "[]): " + T + " { return xs.length > 0 ? xs[xs.length - 1] : d; }\n");
		return X;
	}

	growth(): int32 { return this.mult > (SEQ_LEN_CAP as int64) ? SEQ_LEN_CAP : (this.mult as int32); }

	hasRoom(v: Ent): boolean { return v.len + this.growth() <= SEQ_LEN_CAP; }

	tupleType(params: Ty[]): string {
		let out = "";
		for (const p of params) { out = out == "" ? tyName(p) : out + ", " + tyName(p); }
		return "[" + out + "]";
	}

	tupleEnts(writable: boolean): Ent[] {
		const out: Ent[] = [];
		for (const e of this.ents) {
			if (e.kind == EntKind.TupleVar || (!writable && e.kind == EntKind.TupleFrozen)) { out.push(e); }
		}
		return out;
	}

	componentsOf(e: Ent, t: Ty): int32[] {
		const out: int32[] = [];
		for (let k = 0; k < e.params.length; k++) { if (e.params[k] == t) { out.push(k); } }
		return out;
	}

	tuplesHolding(t: Ty): Ent[] {
		const out: Ent[] = [];
		if (this.bodyDepth > 0) { return out; }
		for (const e of this.tupleEnts(false)) { if (this.componentsOf(e, t).length > 0) { out.push(e); } }
		return out;
	}

	freezeTuple(name: string): void {
		for (let i = 0; i < this.ents.length; i++) {
			if (this.ents[i].name == name) { this.ents[i].kind = EntKind.TupleFrozen; }
		}
	}

	setLen(name: string, len: int32): void {
		for (let i = 0; i < this.ents.length; i++) {
			if (this.ents[i].name == name) { this.ents[i].len = len; }
		}
	}

	seqExpr(t: Ty, depth: int32): string {
		const k = this.pickW(W.SeqElem, W.SeqBorrow);
		if (k == 0) { return this.seqElem(t, depth); }
		if (k == 1) { return this.seqSize(t, depth); }
		if (k == 2) { return this.seqSpan(t, depth); }
		return this.seqBorrow(t, depth);
	}

	vecElem(v: string, t: Ty, depth: int32): string {
		this.ixHelper();
		return "(" + v + ".length > 0 ? " + v + "[ixI(" + this.smallInt(depth) + ", " + v + ".length as int32)] : " + this.elseExpr(t, depth) + ")";
	}

	seqElem(t: Ty, depth: int32): string {
		const tuples = this.tuplesHolding(t);
		const vecs = this.liveOf(EntKind.VecVar, t);
		if (tuples.length > 0 && (vecs.length == 0 || this.rng.chance(50))) {
			const e = this.pickEnt(tuples);
			const at = this.componentsOf(e, t);
			return e.name + "[" + String(at[this.rng.below(at.length)]) + "]";
		}
		if (vecs.length == 0) { return ""; }
		return this.ternary(this.vecElem(this.pickEnt(vecs).name, t, depth));
	}

	seqSize(t: Ty, depth: int32): string {
		const vecs = this.liveAny(EntKind.VecVar);
		if (t == Ty.Int32 && vecs.length > 0) {
			const v = this.pickEnt(vecs);
			const form = this.rng.below(5);
			if (form == 1 && !isFloat(v.ty)) { return "(" + v.name + ".indexOf(" + this.expr(v.ty, depth + 1) + ") as int32)"; }
			if (form == 2) { return v.name + ".join(\",\").length"; }
			if (form == 3) {
				const from = this.rng.below(3);
				return v.name + ".slice(" + String(from) + ", " + String(from + this.rng.below(4)) + ").length";
			}
			if (form == 4) { return v.name + ".concat([" + this.items(v.ty, depth, this.rng.between(1, 2)) + "]).length"; }
			return "(" + v.name + ".length as int32)";
		}
		if (isFloat(t)) { return ""; }
		const owners = this.liveOf(EntKind.VecVar, t);
		if (owners.length == 0) { return ""; }
		const o = this.pickEnt(owners);
		return this.ternary("(" + o.name + ".includes(" + this.expr(t, depth + 1) + ") ? " + this.expr(t, depth + 1) + " : " + this.elseExpr(t, depth) + ")");
	}

	seqSpan(t: Ty, depth: int32): string {
		const vecs = this.liveOf(EntKind.VecVar, t);
		if (vecs.length == 0) { return ""; }
		const X = this.spanHelpers(t);
		const v = this.pickEnt(vecs).name;
		if (this.rng.chance(50)) {
			return "spanAt" + X + "(" + v + ", " + this.smallInt(depth) + ", " + this.expr(t, depth + 1) + ")";
		}
		const lo = this.rng.below(2);
		const hi = lo + this.rng.between(1, 3);
		const view = v + "[" + String(lo) + ".." + String(hi) + "]";
		const text = "(" + v + ".length >= " + String(hi) + " ? spanAt" + X + "(" + view + ", " + this.smallInt(depth) + ", " + this.expr(t, depth + 1) + ") : " + this.elseExpr(t, depth) + ")";
		return this.ternary(text);
	}

	seqBorrow(t: Ty, depth: int32): string {
		const T = tyName(t);
		const tuples = this.tuplesHolding(t);
		const vecs = this.liveOf(EntKind.VecVar, t);
		this.kit("readG");
		if (tuples.length > 0 && (vecs.length == 0 || this.rng.chance(50))) {
			const e = this.pickEnt(tuples);
			const at = this.componentsOf(e, t);
			return "readG<" + T + ">(" + e.name + "[" + String(at[this.rng.below(at.length)]) + "], " + this.expr(t, depth + 1) + ")";
		}
		if (vecs.length > 0 && this.rng.chance(70)) {
			const v = this.pickEnt(vecs).name;
			this.ixHelper();
			const place = v + "[ixI(" + this.smallInt(depth) + ", " + v + ".length as int32)]";
			const text = "(" + v + ".length > 0 ? readG<" + T + ">(" + place + ", " + this.expr(t, depth + 1) + ") : " + this.elseExpr(t, depth) + ")";
			return this.ternary(text);
		}
		const vars = this.visible(t, false);
		if (vars.length == 0) { return ""; }
		return "readG<" + T + ">(" + vars[this.rng.below(vars.length)].name + ", " + this.expr(t, depth + 1) + ")";
	}

	seqStatement(t: Ty, indent: string): string {
		if (!this.reserve(2 as int64)) { return ""; }
		const k = this.pickW(W.SeqTuple, W.SeqLoop);
		if (k == 0) { return this.seqTuple(t, indent); }
		if (k == 1) { return this.seqTupleEdit(t, indent); }
		if (k == 2) { return this.seqVec(t, indent); }
		if (k == 3) { return this.seqVecEdit(t, indent); }
		if (k == 4) { return this.seqSpread(t, indent); }
		if (k == 5) { return this.seqDestruct(t, indent, false); }
		if (k == 6) { return this.seqDestruct(t, indent, true); }
		if (k == 7) { return this.seqSpanSet(t, indent); }
		if (k == 8) { return this.seqRef(t, indent); }
		if (k == 9) { return this.seqMove(t, indent); }
		return this.seqLoop(t, indent);
	}

	seqTuple(t: Ty, indent: string): string {
		const pairs: Ent[] = [];
		for (const e of this.tupleEnts(false)) { if (e.params.length == 2) { pairs.push(e); } }
		const form = this.rng.below(pairs.length > 0 ? 3 : 2);
		if (form == 2) {
			this.kit("swapT");
			const src = this.pickEnt(pairs);
			const A = tyName(src.params[0]);
			const B = tyName(src.params[1]);
			const name = this.entName("n");
			this.pushEnt(EntKind.TupleVar, name, src.params[1], [src.params[1], src.params[0]], 2, 0 as int64);
			return indent + "let " + name + ": [" + B + ", " + A + "] = swapT<" + A + ", " + B + ">(" + src.name + ");\n";
		}
		const params: Ty[] = [t];
		const n = form == 1 ? 2 : this.rng.between(2, 3);
		for (let i = 1; i < n; i++) { params.push(this.pickTy()); }
		let items = "";
		for (const p of params) {
			const e = this.expr(p, 0);
			items = items == "" ? e : items + ", " + e;
		}
		const name = this.entName("n");
		this.pushEnt(EntKind.TupleVar, name, t, params, n, 0 as int64);
		if (form == 1) {
			this.kit("pairT");
			const A = tyName(params[0]);
			const B = tyName(params[1]);
			return indent + "let " + name + ": [" + A + ", " + B + "] = pairT<" + A + ", " + B + ">(" + items + ");\n";
		}
		return indent + "let " + name + ": " + this.tupleType(params) + " = [" + items + "];\n";
	}

	seqTupleEdit(t: Ty, indent: string): string {
		const writable = this.tupleEnts(true);
		const all = this.tupleEnts(false);
		if (all.length == 0) { return this.seqTuple(t, indent); }
		const form = this.rng.below(3);
		if (form == 0 && writable.length > 0) {
			const e = this.pickEnt(writable);
			const k = this.rng.below(e.params.length);
			return indent + e.name + "[" + String(k) + "] = " + this.expr(e.params[k], 0) + ";\n";
		}
		const e = this.pickEnt(all);
		if (form == 1) {
			const n = this.rng.between(1, e.params.length);
			let pattern = "";
			for (let i = 0; i < n; i++) {
				const slot = "l" + String(this.localCount + i) + (this.rng.chance(70) ? " = " + this.expr(e.params[i], 0) : "");
				pattern = pattern == "" ? slot : pattern + ", " + slot;
			}
			for (let i = 0; i < n; i++) { this.newLocal(e.params[i]); }
			return indent + "let [" + pattern + "] = " + e.name + ";\n";
		}
		const name = this.entName("n");
		this.freezeTuple(e.name);
		this.pushEnt(EntKind.TupleFrozen, name, e.ty, e.params, e.params.length, 0 as int64);
		return indent + "let " + name + ": " + this.tupleType(e.params) + " = " + e.name + ";\n";
	}

	newVec(name: string, t: Ty, len: int32): void {
		this.pushEnt(EntKind.VecVar, name, t, [], len, this.blockId as int64);
	}

	seqVec(t: Ty, indent: string): string {
		const T = tyName(t);
		const vecs = this.entsOf(EntKind.VecVar, t);
		const form = this.rng.below(vecs.length > 0 ? 4 : 1);
		if (form == 0) {
			const n = this.rng.below(4);
			const items = this.items(t, -1, n);
			const name = this.entName("v");
			this.newVec(name, t, n);
			return indent + "let " + name + ": Vec<" + T + "> = [" + items + "];\n";
		}
		const src = this.pickEnt(vecs);
		const name = this.entName("v");
		if (form == 1) {
			this.newVec(name, t, src.len);
			return indent + "let " + name + ": Vec<" + T + "> = " + src.name + ";\n";
		}
		if (form == 2) {
			const from = this.rng.below(3);
			this.pushEnt(EntKind.ArrayVar, name, t, [], 0, 0 as int64);
			return indent + "let " + name + ": " + T + "[] = " + src.name + ".slice(" + String(from) + ", " + String(from + this.rng.below(4)) + ");\n";
		}
		const trips = this.rng.between(1, 4);
		const f = this.lambda([t], t, 0, this.spare(trips as int64));
		if (!this.reserve((trips as int64) * f.cost)) { return ""; }
		this.pushEnt(EntKind.ArrayVar, name, t, [], 0, 0 as int64);
		return indent + "let " + name + ": " + T + "[] = " + src.name + ".slice(0, " + String(trips) + ").map(" + f.text + ");\n";
	}

	seqVecEdit(t: Ty, indent: string): string {
		const vecs = this.entsOf(EntKind.VecVar, t);
		if (vecs.length == 0) { return this.seqVec(t, indent); }
		const e = this.pickEnt(vecs);
		const v = e.name;
		let form = this.rng.below(6);
		if (form == 0 && !this.hasRoom(e)) { form = 1; }
		if (form == 0) {
			const value = this.expr(t, 0);
			this.setLen(v, e.len + this.growth());
			return indent + v + ".push(" + value + ");\n";
		}
		const guard = indent + "if (" + v + ".length > 0) { ";
		if (form == 1) {
			this.ixHelper();
			return guard + v + "[ixI(" + this.smallInt(0) + ", " + v + ".length as int32)] = " + this.expr(t, 0) + "; }\n";
		}
		if (form == 2) { return guard + v + ".pop(); }\n"; }
		if (form == 3) {
			this.ixHelper();
			return guard + v + ".splice(ixI(" + this.smallInt(0) + ", " + v + ".length as int32), 1); }\n";
		}
		if (form == 4) { return indent + v + ".fill(" + this.expr(t, 0) + ");\n"; }
		const n = String(this.rng.below(4));
		return indent + "if (" + v + ".length > " + n + ") { " + v + ".setLength(" + n + "); }\n";
	}

	seqSpread(t: Ty, indent: string): string {
		const T = tyName(t);
		const vecs = this.entsOf(EntKind.VecVar, t);
		if (vecs.length == 0) { return this.seqVec(t, indent); }
		const a = this.pickEnt(vecs);
		const b = this.pickEnt(vecs);
		const form = this.rng.below(4);
		if (form == 3) {
			const X = this.spanHelpers(t);
			const d = this.expr(t, 0);
			const name = this.newLocal(t);
			return indent + "let " + name + ": " + T + " = restV" + X + "(" + d + ", ..." + a.name + ");\n";
		}
		if (form == 2) {
			const name = this.entName("a");
			this.pushEnt(EntKind.ArrayVar, name, t, [], 0, 0 as int64);
			return indent + "let " + name + ": " + T + "[] = [..." + a.name + ", " + this.expr(t, 0) + "];\n";
		}
		const joined = form == 1 ? a.len + b.len + 1 : a.len + 1;
		if (joined > SEQ_LEN_CAP) { return this.seqVec(t, indent); }
		const value = form == 1 ? "[" + this.expr(t, 0) + ", ..." + a.name + ", ..." + b.name + "]" : "[..." + a.name + ", " + this.expr(t, 0) + "]";
		const name = this.entName("v");
		this.newVec(name, t, joined);
		return indent + "let " + name + ": Vec<" + T + "> = " + value + ";\n";
	}

	seqDestruct(t: Ty, indent: string, rest: boolean): string {
		const vecs = this.entsOf(EntKind.VecVar, t);
		if (vecs.length == 0) { return this.seqVec(t, indent); }
		const src = this.pickEnt(vecs);
		const n = this.rng.between(1, 3);
		let pattern = "";
		for (let i = 0; i < n; i++) {
			const slot = "l" + String(this.localCount + i) + " = " + this.expr(t, 0);
			pattern = pattern == "" ? slot : pattern + ", " + slot;
		}
		for (let i = 0; i < n; i++) { this.newLocal(t); }
		if (rest) {
			const tail = this.entName("v");
			this.newVec(tail, t, src.len);
			pattern += ", ..." + tail;
			this.directive("// @skip-raiser: the Raiser has no host bridge for msGenericArrayPush, so an array pattern with a rest element stops (inbox/compiler/2026-10-17-raiser-has-no-host-bridge-for-msgenericarraypush)");
		}
		return indent + "let [" + pattern + "] = " + src.name + ";\n";
	}

	seqSpanSet(t: Ty, indent: string): string {
		const vecs = this.entsOf(EntKind.VecVar, t);
		if (vecs.length == 0) { return this.seqVec(t, indent); }
		const X = this.spanHelpers(t);
		const v = this.pickEnt(vecs).name;
		if (this.rng.chance(50)) { return indent + "spanSet" + X + "(" + v + ", " + this.smallInt(0) + ", " + this.expr(t, 0) + ");\n"; }
		const lo = this.rng.below(2);
		const hi = lo + this.rng.between(1, 3);
		return indent + "if (" + v + ".length >= " + String(hi) + ") { spanSet" + X + "(" + v + "[" + String(lo) + ".." + String(hi) + "], " + this.smallInt(0) + ", " + this.expr(t, 0) + "); }\n";
	}

	seqRef(t: Ty, indent: string): string {
		const T = tyName(t);
		const vecs = this.entsOf(EntKind.VecVar, t);
		const writable = this.tupleEnts(true);
		const form = this.rng.below(7);
		if (form == 0 && vecs.length > 0) {
			const e = this.pickEnt(vecs);
			if (this.hasRoom(e)) {
				this.kit("pushQ");
				const value = this.expr(t, 0);
				this.setLen(e.name, e.len + this.growth());
				return indent + "pushQ<" + T + ">(" + e.name + ", " + value + ");\n";
			}
		}
		if (form == 1 && vecs.length > 1) {
			const a = this.pickEnt(vecs);
			const b = this.pickEnt(vecs);
			if (a.name != b.name) {
				this.kit("swapQ");
				const bound = a.len > b.len ? a.len : b.len;
				this.setLen(a.name, bound);
				this.setLen(b.name, bound);
				return indent + "swapQ<Vec<" + T + ">>(" + a.name + ", " + b.name + ");\n";
			}
		}
		if (form == 2) {
			const vars = this.visible(t, true);
			if (vars.length > 1) {
				const a = vars[this.rng.below(vars.length)].name;
				const b = vars[this.rng.below(vars.length)].name;
				if (a != b) {
					this.kit("swapQ");
					return indent + "swapQ<" + T + ">(" + a + ", " + b + ");\n";
				}
			}
		}
		if (form == 3 && vecs.length > 0) {
			const e = this.pickEnt(vecs);
			const n = this.rng.below(4);
			this.kit("fillQ");
			const items = this.items(t, -1, n);
			if (n > e.len) { this.setLen(e.name, n); }
			return indent + "fillQ<Vec<" + T + ">>(out " + e.name + ", [" + items + "]);\n";
		}
		if (form == 4 && writable.length > 0) {
			const e = this.pickEnt(writable);
			let items = "";
			for (const p of e.params) {
				const x = this.expr(p, 0);
				items = items == "" ? x : items + ", " + x;
			}
			this.kit("fillQ");
			return indent + "fillQ<" + this.tupleType(e.params) + ">(out " + e.name + ", [" + items + "]);\n";
		}
		if (form == 5 && writable.length > 1) {
			const a = this.pickEnt(writable);
			const b = this.pickEnt(writable);
			if (a.name != b.name && this.tupleType(a.params) == this.tupleType(b.params)) {
				this.kit("swapQ");
				return indent + "swapQ<" + this.tupleType(a.params) + ">(" + a.name + ", " + b.name + ");\n";
			}
		}
		if (form == 6) {
			const pairs: Ent[] = [];
			for (const e of this.tupleEnts(false)) { if (e.params.length == 2) { pairs.push(e); } }
			if (pairs.length > 0 && this.rng.chance(50)) {
				const e = this.pickEnt(pairs);
				this.kit("firstQ");
				const name = this.newLocal(e.params[0]);
				return indent + "let " + name + ": " + tyName(e.params[0]) + " = firstQ<" + tyName(e.params[0]) + ", " + tyName(e.params[1]) + ">(" + e.name + ");\n";
			}
			if (vecs.length > 0) {
				this.kit("headQ");
				const e = this.pickEnt(vecs);
				const d = this.expr(t, 0);
				const name = this.newLocal(t);
				return indent + "let " + name + ": " + T + " = headQ<" + T + ">(" + e.name + ", " + d + ");\n";
			}
		}
		return this.seqVec(t, indent);
	}

	seqMove(t: Ty, indent: string): string {
		const T = tyName(t);
		const movable: Ent[] = [];
		for (const e of this.entsOf(EntKind.VecVar, t)) { if (e.cost == (this.blockId as int64)) { movable.push(e); } }
		if (movable.length == 0) { return this.seqVec(t, indent); }
		const m = this.pickEnt(movable);
		this.dropEnt(m.name);
		this.kit("takeQ");
		if (this.rng.chance(50)) {
			const name = this.entName("v");
			this.newVec(name, t, m.len);
			return indent + "let " + name + ": Vec<" + T + "> = takeQ<Vec<" + T + ">>(move " + m.name + ");\n";
		}
		this.kit("CellQ");
		this.kit("headQ");
		const cell = this.entName("c");
		const seed = this.expr(t, 0);
		const d = this.expr(t, 0);
		const name = this.newLocal(t);
		return indent + "const " + cell + " = new CellQ<Vec<" + T + ">>([" + seed + "]);\n" +
			indent + cell + ".set(move " + m.name + ");\n" +
			indent + "let " + name + ": " + T + " = headQ<" + T + ">(" + cell + ".get(), " + d + ");\n";
	}

	seqLoop(t: Ty, indent: string): string {
		const vecs = this.entsOf(EntKind.VecVar, t);
		if (vecs.length == 0) { return this.seqVec(t, indent); }
		return this.collLoop(t, this.pickEnt(vecs).name, indent);
	}

	gclsExpr(t: Ty, depth: int32): string {
		const k = this.pickW(W.GclsCell, W.GclsWrap);
		if (k == 0) { return this.gclsCell(t, depth); }
		if (k == 1) { return this.gclsMap(t, depth); }
		if (k == 2) { return this.gclsNest(t, depth); }
		if (k == 3) { return this.gclsPair(t, depth); }
		if (k == 4) { return this.gclsStack(t, depth); }
		if (k == 5) { return this.gclsBest(t, depth); }
		return this.gclsWrap(t, depth);
	}

	gclsCell(t: Ty, depth: int32): string {
		const T = tyName(t);
		this.kit("CellQ");
		const cells = this.liveOf(EntKind.CellVar, t);
		const form = this.rng.below(4);
		if (form == 0 && cells.length > 0) {
			const c = this.pickEnt(cells).name;
			return this.rng.chance(50) ? c + ".get()" : c + ".v";
		}
		if (form == 1 && cells.length > 0) {
			this.kit("idQ");
			return "idQ(" + this.pickEnt(cells).name + ").get()";
		}
		if (form == 2) {
			this.kit("idQ");
			return "idQ<CellQ<" + T + ">>(new CellQ<" + T + ">(" + this.expr(t, depth + 1) + ")).get()";
		}
		return "new CellQ<" + T + ">(" + this.expr(t, depth + 1) + ").get()";
	}

	gclsMap(t: Ty, depth: int32): string {
		const T = tyName(t);
		this.kit("CellQ");
		const u = this.pickTy();
		const f = this.lambda([u], t, depth, this.spare(1 as int64));
		if (!this.reserve(f.cost)) { return ""; }
		const cells = this.liveOf(EntKind.CellVar, u);
		if (cells.length > 0 && this.rng.chance(60)) {
			return this.pickEnt(cells).name + ".map<" + T + ">(" + f.text + ").get()";
		}
		return "new CellQ<" + tyName(u) + ">(" + this.expr(u, depth + 1) + ").map<" + T + ">(" + f.text + ").get()";
	}

	gclsNest(t: Ty, depth: int32): string {
		const T = tyName(t);
		this.kit("CellQ");
		const nests = this.liveOf(EntKind.NestVar, t);
		const form = this.rng.below(3);
		if (form == 0 && nests.length > 0) {
			const n = this.pickEnt(nests).name;
			return this.rng.chance(50) ? n + ".get().get()" : n + ".v.v";
		}
		const inner = "new CellQ<" + T + ">(" + this.expr(t, depth + 1) + ")";
		if (form == 2) { return "new CellQ<CellQ<CellQ<" + T + ">>>(new CellQ<CellQ<" + T + ">>(" + inner + ")).v.v.v"; }
		return "new CellQ<CellQ<" + T + ">>(" + inner + ").get().get()";
	}

	gclsPair(t: Ty, depth: int32): string {
		const T = tyName(t);
		this.kit("CellQ");
		const pairs: Ent[] = [];
		for (const e of this.ents) {
			if (e.kind == EntKind.PairVar && this.bodyDepth == 0 && this.componentsOf(e, t).length > 0) { pairs.push(e); }
		}
		const form = this.rng.below(3);
		if (form == 0 && pairs.length > 0) {
			const p = this.pickEnt(pairs);
			const at = this.componentsOf(p, t);
			const first = at[this.rng.below(at.length)] == 0;
			const swapped = this.rng.chance(40);
			if (swapped) { return p.name + ".swap()." + (first ? "second()" : "first()"); }
			return p.name + (first ? (this.rng.chance(50) ? ".a" : ".first()") : (this.rng.chance(50) ? ".b" : ".second()"));
		}
		const u = this.pickTy();
		const U = tyName(u);
		if (form == 1) { return "new PairQ<" + U + ", " + T + ">(" + this.expr(u, depth + 1) + ", " + this.expr(t, depth + 1) + ").swap().first()"; }
		return "new CellQ<" + T + ">(" + this.expr(t, depth + 1) + ").pairWith<" + U + ">(" + this.expr(u, depth + 1) + ").first()";
	}

	gclsStack(t: Ty, depth: int32): string {
		const T = tyName(t);
		this.kit("StackQ");
		const stacks = this.liveOf(EntKind.StackVar, t);
		if (t == Ty.Int32 && this.rng.chance(40)) {
			const any = this.liveAny(EntKind.StackVar);
			if (any.length > 0) { return this.pickEnt(any).name + ".size()"; }
		}
		if (stacks.length > 0) { return this.pickEnt(stacks).name + ".top(" + this.expr(t, depth + 1) + ")"; }
		return "new StackQ<" + T + ">().top(" + this.expr(t, depth + 1) + ")";
	}

	gclsBest(t: Ty, depth: int32): string {
		const T = tyName(t);
		this.kit("ItemQ");
		const items = this.liveOf(EntKind.ItemVar, t);
		if (items.length > 1 && this.rng.chance(60)) {
			const a = this.pickEnt(items).name;
			const b = this.pickEnt(items).name;
			if (a != b) {
				const field = t == Ty.Int32 && this.rng.chance(30) ? ".key" : ".v";
				return this.rng.chance(50) ? "bestQ(" + a + ", " + b + ")" + field : "bestQ<ItemQ<" + T + ">>(" + b + ", " + a + ")" + field;
			}
		}
		const left = "new ItemQ<" + T + ">(" + String(this.rng.below(6)) + ", " + this.expr(t, depth + 1) + ")";
		const right = "new ItemQ<" + T + ">(" + String(this.rng.below(6)) + ", " + this.expr(t, depth + 1) + ")";
		return "bestQ<ItemQ<" + T + ">>(" + left + ", " + right + ").v";
	}

	gclsWrap(t: Ty, depth: int32): string {
		const T = tyName(t);
		this.kit("WrapQ");
		const form = this.rng.below(4);
		if (form == 0) { return "unwrapQ<" + T + ">(newWrapQ<" + T + ">(" + this.expr(t, depth + 1) + ", " + this.smallInt(depth) + "))"; }
		if (form == 1) {
			const inner = "newWrapQ<" + T + ">(" + this.expr(t, depth + 1) + ", " + this.smallInt(depth) + ")";
			return "unwrapQ<" + T + ">(unwrapQ<WrapQ<" + T + ">>(newWrapQ<WrapQ<" + T + ">>(" + inner + ", " + this.smallInt(depth) + ")))";
		}
		if (form == 2) {
			if (t == Ty.Int32 && this.rng.chance(40)) { return "holdQ<" + T + ">(" + this.expr(t, depth + 1) + ", " + this.smallInt(depth) + ").n"; }
			return "holdQ<" + T + ">(" + this.expr(t, depth + 1) + ", " + this.smallInt(depth) + ").item";
		}
		const inner = "newWrapQ<" + T + ">(" + this.expr(t, depth + 1) + ", " + this.smallInt(depth) + ")";
		return "holdQ<WrapQ<" + T + ">>(" + inner + ", " + this.smallInt(depth) + ").item.v";
	}

	gclsStatement(t: Ty, indent: string): string {
		if (!this.reserve(3 as int64)) { return ""; }
		const k = this.pickW(W.GclsDecl, W.GclsOwn);
		if (k == 0) { return this.gclsDecl(t, indent); }
		if (k == 1) { return this.gclsSet(t, indent); }
		if (k == 2) { return this.gclsRef(t, indent); }
		return this.gclsOwn(t, indent);
	}

	gclsDecl(t: Ty, indent: string): string {
		const T = tyName(t);
		const form = this.rng.below(5);
		if (form == 0) {
			this.kit("CellQ");
			const value = this.expr(t, 0);
			const name = this.entName("c");
			this.pushEnt(EntKind.CellVar, name, t, [], 0, 0 as int64);
			return indent + "let " + name + " = new CellQ<" + T + ">(" + value + ");\n";
		}
		if (form == 1) {
			this.kit("CellQ");
			const value = this.expr(t, 0);
			const name = this.entName("n");
			this.pushEnt(EntKind.NestVar, name, t, [], 0, 0 as int64);
			return indent + "let " + name + " = new CellQ<CellQ<" + T + ">>(new CellQ<" + T + ">(" + value + "));\n";
		}
		if (form == 2) {
			this.kit("PairQ");
			const u = this.pickTy();
			const a = this.expr(t, 0);
			const b = this.expr(u, 0);
			const name = this.entName("z");
			this.pushEnt(EntKind.PairVar, name, t, [t, u], 0, 0 as int64);
			return indent + "const " + name + " = new PairQ<" + T + ", " + tyName(u) + ">(" + a + ", " + b + ");\n";
		}
		if (form == 3) {
			this.kit("StackQ");
			const value = this.expr(t, 0);
			const name = this.entName("s");
			this.pushEnt(EntKind.StackVar, name, t, [], 1, 0 as int64);
			return indent + "const " + name + " = new StackQ<" + T + ">();\n" + indent + name + ".push(" + value + ");\n";
		}
		this.kit("ItemQ");
		const value = this.expr(t, 0);
		const name = this.entName("k");
		this.pushEnt(EntKind.ItemVar, name, t, [], 0, 0 as int64);
		return indent + "const " + name + " = new ItemQ<" + T + ">(" + String(this.rng.below(6)) + ", " + value + ");\n";
	}

	gclsSet(t: Ty, indent: string): string {
		const held: Ent[] = [];
		for (const e of this.ents) {
			if (e.kind == EntKind.CellVar || e.kind == EntKind.NestVar || e.kind == EntKind.PairVar || e.kind == EntKind.StackVar || e.kind == EntKind.ItemVar) { held.push(e); }
		}
		if (held.length == 0) { return this.gclsDecl(t, indent); }
		const e = this.pickEnt(held);
		const T = tyName(e.ty);
		const n = e.name;
		if (e.kind == EntKind.CellVar) {
			return this.rng.chance(50) ? indent + n + ".set(" + this.expr(e.ty, 0) + ");\n" : indent + n + ".v = " + this.expr(e.ty, 0) + ";\n";
		}
		if (e.kind == EntKind.NestVar) {
			const form = this.rng.below(3);
			if (form == 0) { return indent + n + ".get().set(" + this.expr(e.ty, 0) + ");\n"; }
			if (form == 1) { return indent + n + ".v.v = " + this.expr(e.ty, 0) + ";\n"; }
			return indent + n + ".set(new CellQ<" + T + ">(" + this.expr(e.ty, 0) + "));\n";
		}
		if (e.kind == EntKind.PairVar) {
			const second = this.rng.chance(50);
			return indent + n + (second ? ".b = " : ".a = ") + this.expr(e.params[second ? 1 : 0], 0) + ";\n";
		}
		if (e.kind == EntKind.StackVar) {
			if (this.rng.chance(30)) { return indent + n + ".drop();\n"; }
			if (e.len + this.growth() > SEQ_LEN_CAP) { return indent + n + ".drop();\n"; }
			const value = this.expr(e.ty, 0);
			this.setLen(n, e.len + this.growth());
			return indent + n + ".push(" + value + ");\n";
		}
		return indent + n + ".v = " + this.expr(e.ty, 0) + ";\n";
	}

	gclsRef(t: Ty, indent: string): string {
		const T = tyName(t);
		const cells = this.entsOf(EntKind.CellVar, t);
		const form = this.rng.below(4);
		if (form == 0 && cells.length > 1) {
			const a = this.pickEnt(cells).name;
			const b = this.pickEnt(cells).name;
			if (a != b) {
				this.kit("swapQ");
				return indent + "swapQ<" + T + ">(" + a + ".v, " + b + ".v);\n";
			}
		}
		if (form == 1 && cells.length > 1) {
			const a = this.pickEnt(cells).name;
			const b = this.pickEnt(cells).name;
			if (a != b) {
				this.kit("swapQ");
				return indent + "swapQ<CellQ<" + T + ">>(" + a + ", " + b + ");\n";
			}
		}
		if (form == 2) {
			this.kit("fillQ");
			const value = this.expr(t, 0);
			const name = this.newLocal(t);
			return indent + "let " + name + ": " + T + ";\n" + indent + "fillQ<" + T + ">(out " + name + ", " + value + ");\n";
		}
		if (form == 3 && cells.length > 0) {
			this.kit("roQ");
			const name = this.newLocal(t);
			return indent + "let " + name + ": " + T + " = roQ<CellQ<" + T + ">>(" + this.pickEnt(cells).name + ").get();\n";
		}
		return this.gclsDecl(t, indent);
	}

	gclsOwn(t: Ty, indent: string): string {
		const T = tyName(t);
		const X = this.ownHelpers(t);
		const O = "Own" + X;
		this.kit("swapQ");
		this.kit("takeQ");
		const form = this.rng.below(3);
		const a = this.entName("z");
		const b = this.entName("z");
		const first = this.expr(t, 0);
		const second = this.expr(t, 0);
		const head = indent + "let " + a + ": " + O + " = mkO" + X + "(" + first + ", \"a\");\n" +
			indent + "let " + b + ": " + O + " = mkO" + X + "(" + second + ", \"b\");\n";
		const swap = this.rng.chance(50) ? indent + "swapQ<" + O + ">(" + a + ", " + b + ");\n" : "";
		const name = this.newLocal(t);
		if (form == 0) {
			this.kit("StackQ");
			const s = this.entName("s");
			return indent + "const " + s + " = new StackQ<" + O + ">();\n" + head + swap +
				indent + s + ".push(move " + a + ");\n" +
				indent + s + ".push(" + b + ");\n" +
				indent + "let " + name + ": " + T + " = " + s + ".top(" + b + ").v;\n" +
				indent + s + ".drop();\n";
		}
		if (form == 1) {
			this.kit("CellQ");
			const c = this.entName("c");
			return head + swap +
				indent + "const " + c + " = new CellQ<" + O + ">(" + b + ");\n" +
				indent + c + ".set(move " + a + ");\n" +
				indent + "let " + name + ": " + T + " = " + c + ".get().v;\n";
		}
		const r = this.entName("z");
		return head + swap +
			indent + "let " + r + ": " + O + " = takeQ<" + O + ">(move " + a + ");\n" +
			indent + "let " + name + ": " + T + " = " + r + ".v;\n";
	}

	hasHelper(name: string): boolean {
		for (const n of this.helperNames) { if (n == name) { return true; } }
		return false;
	}

	lift(x: string, t: Ty): string {
		if (t == Ty.Int32) { return x; }
		if (!isFloat(t) && !isSigned(t)) { return this.wrapHelper(Ty.Int32, t) + "(" + x + ")"; }
		if (fitsRaw(Ty.Int32, t)) { return "(" + x + " as " + tyName(t) + ")"; }
		return this.convHelper(Ty.Int32, t) + "(" + x + ")";
	}

	member(et: ETy): string { return et.name + ".M" + String(this.rng.below(et.n)); }

	members(et: ETy, from: int32, to: int32): string {
		let out = "";
		for (let j = from; j < to; j++) { out += (out == "" ? "" : " | ") + et.name + ".M" + String(j); }
		return out;
	}

	enumVars(et: ETy): Ent[] {
		const out: Ent[] = [];
		for (const e of this.ents) { if (e.kind == EntKind.EnumVar && e.len == et.id) { out.push(e); } }
		return out;
	}

	enumType(shape: EShape): ETy {
		const pool: ETy[] = [];
		for (const e of this.eTypes) { if (e.shape == shape) { pool.push(e); } }
		if (pool.length >= 3 || (pool.length > 0 && this.rng.chance(60))) { return pool[this.rng.below(pool.length)]; }
		this.ixHelper();
		const id = this.eTypes.length;
		if (shape == EShape.Bitset) { return this.flagType(id, pool.length); }
		if (shape == EShape.Literal) { return this.literalType(id, pool.length); }
		return this.numericType(id, pool.length);
	}

	numericType(id: int32, k: int32): ETy {
		const name = "En" + String(k);
		const n = this.rng.between(2, 6);
		const vals: int32[] = [];
		let expected = 0;
		for (let j = 0; j < n; j++) {
			let v = expected;
			if (j == 0 && this.rng.chance(25)) {
				v = this.rng.between(-6, -1);
			} else if (this.rng.chance(35)) {
				v = expected + this.rng.between(1, 5);
			}
			vals.push(v);
			expected = v + 1;
		}
		const shuffled = n >= 3 && this.rng.chance(25);
		if (shuffled) {
			const tmp = vals[0];
			vals[0] = vals[n - 1];
			vals[n - 1] = tmp;
		}
		let members = "";
		expected = 0;
		for (let j = 0; j < n; j++) {
			const implicit = !shuffled && vals[j] == expected;
			members += "\tM" + String(j) + (implicit ? "" : " = " + String(vals[j])) + ",\n";
			expected = vals[j] + 1;
		}
		let at = "function at" + name + "(i: int32): " + name + " {\n\tconst r = ixI(i, " + String(n) + ");\n";
		for (let j = 0; j < n - 1; j++) { at += "\tif (r == " + String(j) + ") { return " + name + ".M" + String(j) + "; }\n"; }
		at += "\treturn " + name + ".M" + String(n - 1) + ";\n}\n";
		this.useHelper(name, "enum " + name + " {\n" + members + "}\n" + at);
		const et: ETy = { id: id, shape: EShape.Numeric, name: name, ann: name, n: n, lits: [] };
		this.eTypes.push(et);
		return et;
	}

	flagType(id: int32, k: int32): ETy {
		const name = "Fg" + String(k);
		const n = FLAG_COUNTS[this.rng.below(FLAG_COUNTS.length)];
		let members = "";
		for (let j = 0; j < n; j++) { members += (j == 0 ? "" : ", ") + "M" + String(j); }
		const B = "BitSet<" + name + ">";
		const last = name + ".M" + String(n - 1);
		let raw = "\treturn m.size() as int32;\n";
		if (n <= 32) {
			raw = "\treturn ((m as uint32) % (251 as uint32)) as int32;\n";
		} else if (n <= 64) {
			raw = "\treturn ((m as uint64) % (251 as uint64)) as int32;\n";
		}
		this.useHelper(name, "enum " + name + " { " + members + " }\n" +
			"function bs" + name + "(a: " + B + ", b: " + B + ", f: int32): int32 {\n" +
			"\tconst m = a | b;\n" +
			"\tif (f == 0) { return (a & b).size() as int32; }\n" +
			"\tif (f == 1) { return m.size() as int32; }\n" +
			"\tif (f == 2) { return (a ^ b).size() as int32; }\n" +
			"\tif (f == 3) { return a.difference(b).size() as int32; }\n" +
			"\tif (f == 4) {\n" +
			"\t\tif (a.isSubsetOf(b)) { return 1; }\n" +
			"\t\tif (a.isDisjointFrom(b)) { return 2; }\n" +
			"\t\treturn 3;\n" +
			"\t}\n" +
			"\tif (f == 5) {\n" +
			"\t\tif (a == b) { return 4; }\n" +
			"\t\tif (a.has(" + name + ".M0)) { return 5; }\n" +
			"\t\tif (b.has(" + name + ".M0)) { return 6; }\n" +
			"\t\treturn 7;\n" +
			"\t}\n" +
			"\tif (f == 6) {\n" +
			"\t\tlet s: int32 = 0;\n" +
			"\t\tfor (const x of m) { s += x as int32; }\n" +
			"\t\treturn s;\n" +
			"\t}\n" +
			"\tif (f == 7) { return (a.excl(" + name + ".M0).size() as int32) * 100 + (b.incl(" + last + ").size() as int32); }\n" +
			raw + "}\n");
		const et: ETy = { id: id, shape: EShape.Bitset, name: name, ann: B, n: n, lits: [] };
		this.eTypes.push(et);
		return et;
	}

	literalType(id: int32, k: int32): ETy {
		const name = "Lt" + String(k);
		const lits = LIT_SETS[k].split(",");
		const n = lits.length;
		let union = "";
		for (let j = 0; j < n; j++) { union += (j == 0 ? "" : " | ") + quoted(lits[j]); }
		let at = "function at" + name + "(i: int32): " + name + " {\n\tconst r = ixI(i, " + String(n) + ");\n";
		let next = "function next" + name + "(d: " + name + "): " + name + " {\n";
		let ifc = "function if" + name + "(d: " + name + ", a: int32, b: int32): int32 {\n";
		let mx = "function mx" + name + "(d: " + name + ", a: int32, b: int32): int32 {\n\treturn match (d) {\n";
		for (let j = 0; j < n; j++) {
			const pick = j % 2 == 0 ? "a" : "b";
			if (j < n - 1) {
				at += "\tif (r == " + String(j) + ") { return " + quoted(lits[j]) + "; }\n";
				next += "\tif (d == " + quoted(lits[j]) + ") { return " + quoted(lits[j + 1]) + "; }\n";
				ifc += "\tif (d " + (j % 2 == 0 ? "===" : "==") + " " + quoted(lits[j]) + ") { return " + pick + "; }\n";
			}
			mx += "\t\t" + quoted(lits[j]) + " => " + pick + ",\n";
		}
		at += "\treturn " + quoted(lits[n - 1]) + ";\n}\n";
		next += "\treturn " + quoted(lits[0]) + ";\n}\n";
		ifc += "\treturn b;\n}\n";
		mx += "\t};\n}\n";
		const mw = "function mw" + name + "(d: " + name + ", a: int32, b: int32): int32 {\n\treturn match (d) {\n\t\t" + quoted(lits[0]) + " => a,\n\t\t_ => b,\n\t};\n}\n";
		const cmp = "function cmp" + name + "(d: " + name + ", e: " + name + ", form: int32): int32 {\n" +
			"\tif (form == 0) { if (d == " + quoted(lits[0]) + ") { return 1; } return 2; }\n" +
			"\tif (form == 1) { if (d != " + quoted(lits[1]) + ") { return 3; } return 4; }\n" +
			"\tif (form == 2) { if (d === " + quoted(lits[n - 1]) + ") { return 5; } return 6; }\n" +
			"\tconst s: string = d;\n" +
			"\tconst u: string = e;\n" +
			"\tif (s == u) { return s.length; }\n" +
			"\treturn u.length + 10;\n}\n";
		this.useHelper(name, "type " + name + " = " + union + ";\n" + at + next + ifc + mx + mw + cmp);
		const et: ETy = { id: id, shape: EShape.Literal, name: name, ann: name, n: n, lits: lits };
		this.eTypes.push(et);
		return et;
	}

	enumKit(shape: EShape, variant: int32): ETy {
		for (const e of this.eTypes) { if (e.shape == shape && e.n == variant) { return e; } }
		this.ixHelper();
		const id = this.eTypes.length;
		if (shape == EShape.Distinct) { return this.distinctKit(id, variant); }
		if (shape == EShape.Disc) { return this.discKit(id, variant); }
		return this.unknownKit(id);
	}

	distinctKit(id: int32, variant: int32): ETy {
		const isInt = variant == 0;
		const name = isInt ? "DsI" : "DsF";
		const s = isInt ? "I" : "F";
		const ctor = isInt ? "(ixI(i, 2000) - 1000) as DsI" : "((ixI(i, 2000) - 1000) as float64 * 0.5) as DsF";
		const tail = isInt ? "\treturn (x as int32) + n;\n" : "\treturn (((x as float64) * 2.0) as int32) + n;\n";
		this.useHelper(name, "type " + name + " = distinct " + (isInt ? "int32" : "float64") + ";\n" +
			"function ds" + s + "(i: int32): " + name + " { return " + ctor + "; }\n" +
			"function dsRank" + s + "(xs: " + name + "[], x: " + name + ", f: int32): int32 {\n" +
			"\tlet n: int32 = 0;\n" +
			"\tfor (const v of xs) { if (v < x) { n += 1; } }\n" +
			"\tif (f == 0) { if (xs.includes(x)) { return n + 10; } return n; }\n" +
			"\tif (f == 1) { return n + (xs.indexOf(x) as int32) * 100; }\n" +
			"\tif (f == 2) { if (x == xs[0]) { return n + 1; } if (x != xs[xs.length - 1]) { return n + 2; } return n + 3; }\n" +
			"\tif (f == 3) { if (x >= xs[0]) { return n + 4; } if (x > xs[0]) { return n + 5; } if (x <= xs[0]) { return n + 6; } return n + 7; }\n" +
			tail + "}\n");
		const et: ETy = { id: id, shape: EShape.Distinct, name: name, ann: name, n: variant, lits: [] };
		this.eTypes.push(et);
		return et;
	}

	discKit(id: int32, variant: int32): ETy {
		let name = "Dk0";
		let lits: string[] = ["ifDk0", "mxDk0", "elDk0"];
		let text = "";
		if (variant == 0) {
			text = "type Dk0 =\n\t| { kind: \"c\", r: int32 }\n\t| { kind: \"s\", a: int32, b: int32 }\n\t| { kind: \"t\", x: int32 };\n" +
				"function mkDk0(k: int32, n: int32): Dk0 {\n\tconst m = n % 1000;\n\tconst r = k % 3;\n" +
				"\tif (r == 0) { return { kind: \"c\", r: m }; }\n" +
				"\tif (r == 1 || r == -1) { return { kind: \"s\", a: m, b: m + 1 }; }\n" +
				"\treturn { kind: \"t\", x: m * 2 };\n}\n" +
				"function ifDk0(d: Dk0): int32 {\n\tif (d.kind === \"c\") { return d.r; }\n\tif (d.kind === \"s\") { return d.a + d.b; }\n\treturn d.x;\n}\n" +
				"function mxDk0(d: Dk0): int32 {\n\treturn match (d.kind) {\n\t\t\"c\" => d.r,\n\t\t\"s\" => d.a * 10 + d.b,\n\t\t\"t\" => d.x - 1,\n\t};\n}\n" +
				"function elDk0(d: Dk0): int32 {\n\tif (d.kind === \"c\") { return 1; }\n\telse if (d.kind === \"s\") { return d.a; }\n\telse { return d.x; }\n}\n" +
				"function nvDk0(d: Dk0): int32 {\n\tif (d.kind === \"c\") { return d.r; }\n\tif (d.kind === \"s\") { return d.a; }\n\tif (d.kind === \"t\") { return d.x; }\n\tconst x: never = d;\n\treturn 0;\n}\n";
		} else if (variant == 1) {
			name = "Dm0";
			lits = ["ifDm0", "mxDm0"];
			text = "enum Kd0 { Num, Str, Bin }\n" +
				"type Dm0 = match (kind: Kd0) {\n\tKd0.Num => { value: int32 },\n\tKd0.Str => { text: float64 },\n\tKd0.Bin => { l: int32, r: int32 },\n};\n" +
				"function mkDm0(k: int32, n: int32): Dm0 {\n\tconst m = n % 1000;\n\tconst r = k % 3;\n" +
				"\tif (r == 0) { return { kind: Kd0.Num, value: m }; }\n" +
				"\tif (r == 1 || r == -1) { return { kind: Kd0.Str, text: m as float64 * 0.5 }; }\n" +
				"\treturn { kind: Kd0.Bin, l: m, r: m + 1 };\n}\n" +
				"function ifDm0(d: Dm0): int32 {\n\tif (d.kind === Kd0.Num) { return d.value; }\n\tif (d.kind === Kd0.Str) { return (d.text * 2.0) as int32; }\n\treturn d.l + d.r;\n}\n" +
				"function mxDm0(d: Dm0): int32 {\n\treturn match (d.kind) {\n\t\tKd0.Num => d.value,\n\t\tKd0.Str => (d.text * 4.0) as int32,\n\t\tKd0.Bin => d.l * 100 + d.r,\n\t};\n}\n";
		} else {
			name = "Db0";
			lits = ["ifDb0"];
			text = "type Db0 = match (ok: boolean) {\n\ttrue => { value: float64 },\n\tfalse => { err: int32 },\n};\n" +
				"function mkDb0(k: int32, n: int32): Db0 {\n\tconst m = n % 1000;\n" +
				"\tif (k % 2 == 0) { return { ok: true, value: m as float64 }; }\n" +
				"\treturn { ok: false, err: m };\n}\n" +
				"function ifDb0(d: Db0): int32 {\n\tif (d.ok) { return d.value as int32; }\n\treturn d.err;\n}\n";
		}
		this.useHelper(name, text);
		const et: ETy = { id: id, shape: EShape.Disc, name: name, ann: name, n: variant, lits: lits };
		this.eTypes.push(et);
		return et;
	}

	unknownKit(id: int32): ETy {
		this.useHelper("Cx", "class Cx0 { v: int32; constructor(v: int32) { this.v = v; } }\n" +
			"class Cx1 { w: float64; constructor(w: float64) { this.w = w; } }\n" +
			"class Cx2 extends Cx0 { z: int32 = 5; constructor(v: int32) { super(v); } }\n" +
			"function mkCx(k: int32, n: int32): unknown {\n\tconst m = n % 1000;\n\tconst r = k % 3;\n" +
			"\tif (r == 0) { return new Cx0(m); }\n" +
			"\tif (r == 1 || r == -1) { return new Cx1(m as float64 + 0.5); }\n" +
			"\treturn new Cx2(m);\n}\n" +
			"function scoreCx(u: unknown): int32 {\n\tif (u instanceof Cx2) { return u.v + u.z; }\n\tif (u instanceof Cx0) { return u.v; }\n\tif (u instanceof Cx1) { return (u.w * 2.0) as int32; }\n\treturn -1;\n}\n" +
			"function kindCx(u: unknown): int32 {\n\treturn u instanceof Cx1 ? 1 : u instanceof Cx0 ? 2 : 0;\n}\n" +
			"function castCx(u: unknown): int32 {\n\tif (u instanceof Cx1) { const c = u as Cx1; return (c.w as int32) + 100; }\n\treturn 0;\n}\n");
		const et: ETy = { id: id, shape: EShape.Unknown, name: "Cx", ann: "unknown", n: 0, lits: ["scoreCx", "kindCx", "castCx"] };
		this.eTypes.push(et);
		return et;
	}

	neverHelpers(): void {
		this.useHelper("failN", "function failN(code: int32): never { throw new Error(\"fail\" + String(code)); }\n" +
			"function evenN(i: int32): int32 { return i - i % 2; }\n" +
			"function pickN(i: int32): int32 | null {\n\tif (i % 2 == 0) { return i; }\n\treturn null;\n}\n" +
			"function pickF(i: int32): float64 | null {\n\tif (i % 2 == 0) { return i as float64 * 0.5; }\n\treturn null;\n}\n" +
			"function mustN(x: int32 | null): int32 {\n\tif (x === null) { failN(1); }\n\treturn x;\n}\n" +
			"function mustF(x: float64 | null, k: int32): int32 {\n\tif (x === null) { return failN(k); }\n\treturn (x * 2.0) as int32;\n}\n" +
			"function mustE(x: int32 | string): int32 {\n\tif (typeof x === \"string\") { failN(3); }\n\treturn x;\n}\n");
	}

	aliasKit(t: Ty): string {
		const X = tyTitle(t);
		const T = tyName(t);
		this.ixHelper();
		if (this.hasHelper("Als" + X)) { return X; }
		this.useHelper("Als" + X, "type Als" + X + " = " + T + ";\n" +
			"type Alc" + X + " = Als" + X + ";\n" +
			"type Ala" + X + " = Alc" + X + "[];\n" +
			"type Alf" + X + " = (x: Alc" + X + ") => Als" + X + ";\n" +
			"type Alp" + X + " = { a: Alc" + X + ", b: Als" + X + " };\n" +
			"type Alb" + X + "<V> = { v: V };\n" +
			"function alsId" + X + "(x: Alc" + X + "): Als" + X + " { return x; }\n" +
			"function alsAt" + X + "(xs: Ala" + X + ", i: int32, d: Alc" + X + "): Als" + X + " {\n" +
			"\tif (xs.length == 0) { return d; }\n" +
			"\treturn xs[ixI(i, xs.length)];\n}\n" +
			"function alsApp" + X + "(f: Alf" + X + ", x: Als" + X + "): Alc" + X + " { return f(x); }\n" +
			"function alsPair" + X + "(p: Alp" + X + ", q: { a: " + T + ", b: " + T + " }): Als" + X + " {\n" +
			"\tif (p.a == q.a) { return p.b; }\n" +
			"\treturn q.b;\n}\n" +
			"function alsBox" + X + "(b: Alb" + X + "<Als" + X + ">, c: Alb" + X + "<" + T + ">): Alc" + X + " {\n" +
			"\tif (b.v == c.v) { return b.v; }\n" +
			"\treturn c.v;\n}\n");
		return X;
	}

	selHelper(et: ETy, t: Ty): string {
		const name = "sel" + et.name + tyTitle(t);
		if (this.hasHelper(name)) { return name; }
		const T = tyName(t);
		const E = et.name;
		return this.useHelper(name, "function " + name + "(e: " + E + ", f: " + E + ", form: int32, x: " + T + ", y: " + T + "): " + T + " {\n" +
			"\tif (form == 0) { if (e == f) { return x; } return y; }\n" +
			"\tif (form == 1) { if (e != f) { return x; } return y; }\n" +
			"\tif (form == 2) { if (e === f) { return x; } return y; }\n" +
			"\tif ((e as int32) < (f as int32)) { return x; }\n" +
			"\treturn y;\n}\n");
	}

	matchHelper(et: ETy, t: Ty): string {
		const name = "m" + et.name + tyTitle(t);
		if (this.hasHelper(name)) { return name; }
		const T = tyName(t);
		const n = et.n;
		const c1 = this.rng.between(1, n - 1);
		const c2 = this.rng.between(c1, n - 1);
		let arms = "\t\t" + this.members(et, 0, c1) + " => a,\n";
		if (c2 > c1) {
			if (this.rng.chance(40)) { arms += "\t\t" + this.members(et, c1, c2) + " when a < c => c,\n"; }
			arms += "\t\t" + this.members(et, c1, c2) + " => b,\n";
		}
		if (this.rng.chance(30)) {
			arms += "\t\t" + this.members(et, c2, n) + " => c,\n";
		} else {
			arms += "\t\t_ => c,\n";
		}
		return this.useHelper(name, "function " + name + "(e: " + et.name + ", a: " + T + ", b: " + T + ", c: " + T + "): " + T + " {\n" +
			"\treturn match (e) {\n" + arms + "\t};\n}\n");
	}

	eValue(et: ETy, depth: int32): string {
		const vars = this.enumVars(et);
		if (vars.length > 0 && this.rng.chance(40)) { return this.pickEnt(vars).name; }
		if (et.shape == EShape.Bitset) { return this.maskExpr(et, 0); }
		if (et.shape == EShape.Numeric && this.rng.chance(40)) { return this.member(et); }
		if (et.shape == EShape.Literal && this.rng.chance(30)) { return quoted(et.lits[this.rng.below(et.n)]); }
		const s = this.smallInt(depth);
		if (et.shape == EShape.Numeric || et.shape == EShape.Literal) { return "at" + et.name + "(" + s + ")"; }
		if (et.shape == EShape.Distinct) { return "ds" + et.name.slice(2, et.name.length) + "(" + s + ")"; }
		return "mk" + et.name + "(" + s + ", " + this.smallInt(depth) + ")";
	}

	maskExpr(et: ETy, depth: int32): string {
		const vars = this.enumVars(et);
		if (vars.length > 0 && this.rng.chance(40)) { return this.pickEnt(vars).name; }
		let s = "(0 as " + et.ann + ")";
		const m = this.rng.between(0, 3);
		for (let j = 0; j < m; j++) { s += ".incl(" + this.member(et) + ")"; }
		if (depth < 2 && this.rng.chance(30)) { return "(" + s + " " + this.pickOp(BIT_OPS) + " " + this.maskExpr(et, depth + 1) + ")"; }
		return s;
	}

	maskUpdate(et: ETy, v: string, indent: string): string {
		const k = this.rng.below(5);
		if (k == 0) { return indent + v + " |= " + this.member(et) + ";\n"; }
		if (k == 1) { return indent + v + " &= " + this.maskExpr(et, 0) + ";\n"; }
		if (k == 2) { return indent + v + " ^= " + this.maskExpr(et, 0) + ";\n"; }
		if (k == 3) { return indent + v + " = " + v + ".excl(" + this.member(et) + ");\n"; }
		return indent + v + " = " + v + ".incl(" + this.member(et) + ").union(" + this.maskExpr(et, 0) + ");\n";
	}

	shapeType(shape: EShape): ETy {
		if (shape == EShape.Bitset) { return this.enumType(EShape.Bitset); }
		if (shape == EShape.Literal) { return this.enumType(EShape.Literal); }
		if (shape == EShape.Distinct) { return this.enumKit(EShape.Distinct, this.rng.below(2)); }
		if (shape == EShape.Disc) { return this.enumKit(EShape.Disc, this.rng.below(3)); }
		if (shape == EShape.Unknown) { return this.enumKit(EShape.Unknown, 0); }
		return this.enumType(EShape.Numeric);
	}

	enumExpr(t: Ty, depth: int32): string {
		const shape = E_SHAPES[this.pickW(W.EnumNumeric, W.EnumNever)];
		if (shape == EShape.Alias) { return this.aliasExpr(t, depth); }
		if (shape == EShape.Never) { return this.neverExpr(t, depth); }
		if (!this.reserve(6 as int64)) { return ""; }
		const et = this.shapeType(shape);
		if (shape == EShape.Numeric) {
			const a = this.eValue(et, depth + 1);
			if (this.rng.chance(50)) { return this.lift("(" + a + " as int32)", t); }
			const sel = this.selHelper(et, t);
			const b = this.eValue(et, depth + 1);
			return sel + "(" + a + ", " + b + ", " + String(this.rng.below(4)) + ", " + this.expr(t, depth + 1) + ", " + this.expr(t, depth + 1) + ")";
		}
		if (shape == EShape.Match) {
			const m = this.matchHelper(et, t);
			const e = this.eValue(et, depth + 1);
			return m + "(" + e + ", " + this.expr(t, depth + 1) + ", " + this.expr(t, depth + 1) + ", " + this.expr(t, depth + 1) + ")";
		}
		if (shape == EShape.Bitset) {
			if (!this.reserve(et.n as int64)) { return ""; }
			const a = this.maskExpr(et, 0);
			const b = this.maskExpr(et, 0);
			return this.lift("bs" + et.name + "(" + a + ", " + b + ", " + String(this.rng.below(9)) + ")", t);
		}
		if (shape == EShape.Distinct) {
			const s = et.name.slice(2, et.name.length);
			const m = this.rng.between(1, 3);
			let xs = "";
			for (let j = 0; j < m; j++) { xs += (j == 0 ? "" : ", ") + this.eValue(et, depth + 1); }
			const x = this.eValue(et, depth + 1);
			return this.lift("dsRank" + s + "([" + xs + "], " + x + ", " + String(this.rng.below(5)) + ")", t);
		}
		if (shape == EShape.Literal) {
			const d = this.eValue(et, depth + 1);
			const k = this.rng.below(4);
			if (k == 3) { return this.lift("cmp" + et.name + "(" + d + ", " + this.eValue(et, depth + 1) + ", " + String(this.rng.below(4)) + ")", t); }
			const f = k == 0 ? "if" : k == 1 ? "mw" : "mx";
			return this.lift(f + et.name + "(" + d + ", " + String(this.rng.between(-9, 9)) + ", " + String(this.rng.between(-9, 9)) + ")", t);
		}
		return this.lift(et.lits[this.rng.below(et.lits.length)] + "(" + this.eValue(et, depth + 1) + ")", t);
	}

	aliasExpr(t: Ty, depth: int32): string {
		if (!this.reserve(6 as int64)) { return ""; }
		const X = this.aliasKit(t);
		const k = this.rng.below(5);
		if (k == 0) { return "alsId" + X + "(" + this.expr(t, depth + 1) + ")"; }
		if (k == 1) {
			const xs = "[" + this.expr(t, depth + 1) + ", " + this.expr(t, depth + 1) + "]";
			return "alsAt" + X + "(" + xs + ", " + this.smallInt(depth) + ", " + this.expr(t, depth + 1) + ")";
		}
		if (k == 2) {
			const f = this.lambda([t], t, depth, this.spare(1 as int64));
			if (!this.reserve(f.cost)) { return ""; }
			return "alsApp" + X + "(" + f.text + ", " + this.expr(t, depth + 1) + ")";
		}
		if (k == 3) {
			const p = "{ a: " + this.expr(t, depth + 1) + ", b: " + this.expr(t, depth + 1) + " }";
			return "alsPair" + X + "(" + p + ", { a: " + this.expr(t, depth + 1) + ", b: " + this.expr(t, depth + 1) + " })";
		}
		return "alsBox" + X + "({ v: " + this.expr(t, depth + 1) + " }, { v: " + this.expr(t, depth + 1) + " })";
	}

	neverExpr(t: Ty, depth: int32): string {
		if (!this.reserve(6 as int64)) { return ""; }
		this.neverHelpers();
		const k = this.rng.below(4);
		const s = this.smallInt(depth + 1);
		if (k == 0) { return this.lift("mustN(pickN(evenN(" + s + ")))", t); }
		if (k == 1) { return this.lift("mustE(" + s + ")", t); }
		if (k == 2) { return this.lift("mustF(pickF(evenN(" + s + ")), " + String(this.rng.below(9)) + ")", t); }
		const et = this.enumKit(EShape.Disc, 0);
		return this.lift("nvDk0(" + this.eValue(et, depth + 1) + ")", t);
	}

	enumStatement(t: Ty, indent: string, depth: int32): string {
		const shape = E_SHAPES[this.pickW(W.EnumNumeric, W.EnumNever)];
		if (shape == EShape.Alias) {
			const X = this.aliasKit(t);
			const value = this.expr(t, 0);
			return indent + "let " + this.newLocal(t) + ": Alc" + X + " = " + value + ";\n";
		}
		if (shape == EShape.Never) {
			const value = this.neverExpr(t, 0);
			if (value == "") { return ""; }
			return indent + "let " + this.newLocal(t) + ": " + tyName(t) + " = " + value + ";\n";
		}
		const et = this.shapeType(shape);
		const vars = this.enumVars(et);
		if (vars.length > 0 && this.rng.chance(60)) {
			const v = this.pickEnt(vars).name;
			if (et.shape == EShape.Bitset) { return this.maskUpdate(et, v, indent); }
			if (et.shape == EShape.Literal && this.rng.chance(50)) { return indent + v + " = next" + et.name + "(" + v + ");\n"; }
			return indent + v + " = " + this.eValue(et, 0) + ";\n";
		}
		const value = this.eValue(et, 0);
		const name = this.entName("z");
		this.ents.push({ kind: EntKind.EnumVar, name: name, ty: Ty.Int32, params: [], len: et.id, cost: 0 as int64 });
		return indent + "let " + name + ": " + et.ann + " = " + value + ";\n";
	}

	routineDecl(t: Ty, indent: string): string {
		const outer: Var[] = [];
		for (const v of this.scope) {
			if (v.ty == t) { outer.push(v); }
		}
		const name = this.entName("r");
		const n = this.entName("q");
		this.scope.push({ name: n, ty: Ty.Int32, writable: false });
		const body = this.routine(t, 1, FN_COST_CAP);
		this.scope.pop();
		const cost = body.cost + (ROUTINE_FRAMES as int64);
		this.ents.push({ kind: EntKind.Callable, name: name, ty: t, params: [Ty.Int32], len: 0, cost: cost });
		const head = this.rng.chance(50) && !this.atTop ? "function " + name + "(" + n + ": int32): " + tyName(t) + " {\n" : "const " + name + " = (" + n + ": int32): " + tyName(t) + " => {\n";
		let text = indent + head +
			indent + "\tif (" + n + " <= 0 || " + n + " >= " + String(ROUTINE_FRAMES) + ") { return " + body.text + "; }\n" +
			(outer.length == 0 ? "" : indent + "\tif (" + n + " == 2) { return " + outer[this.rng.below(outer.length)].name + "; }\n") +
			indent + "\treturn " + name + "(" + n + " - 1);\n" +
			indent + (head.startsWith("const ") ? "};\n" : "}\n");
		if (this.rng.chance(50)) {
			const alias = this.entName("k");
			this.ents.push({ kind: EntKind.Callable, name: alias, ty: t, params: [Ty.Int32], len: 0, cost: cost });
			text += indent + "const " + alias + " = " + name + ";\n";
		}
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
		if (this.fams.length > 0 && this.rng.chance(this.wt(W.StmtFam))) {
			const fam = this.famStatement(indent, depth);
			if (fam != "") { return fam; }
		}
		const nested = depth < this.depthMax;
		let total = 0;
		for (let i = W.StmtLet as int32; i <= (W.StmtReturn as int32); i++) { total += this.w[i]; }
		const k = this.rng.below(total);
		const cLet = this.wt(W.StmtLet);
		const cAssign = cLet + this.wt(W.StmtAssign);
		const cCompound = cAssign + this.wt(W.StmtCompound);
		const cIf = cCompound + this.wt(W.StmtIf);
		const cFor = cIf + this.wt(W.StmtFor);
		const cMatch = cFor + this.wt(W.StmtMatch);
		const cBreak = cMatch + this.wt(W.StmtBreak);
		if (k < cLet) {
			const t = this.pickTy();
			const value = this.expr(t, 0);
			return indent + "let " + this.newLocal(t) + ": " + tyName(t) + " = " + value + ";\n";
		}
		if (k < cAssign && this.wt(W.StmtAssign) > 0) {
			const t = this.pickTy();
			const vars = this.visible(t, true);
			if (vars.length > 0) {
				const v = vars[this.rng.below(vars.length)];
				return indent + v.name + " = " + this.expr(t, 0) + ";\n";
			}
		}
		if (k < cCompound && this.wt(W.StmtCompound) > 0) {
			const t = this.pickTy();
			const vars = this.visible(t, true);
			if (vars.length > 0 && !trapsOnOverflow(t)) {
				const v = vars[this.rng.below(vars.length)];
				const op = ["+=", "-=", "*="][this.rng.below(3)];
				return indent + v.name + " " + op + " " + this.expr(t, 0) + ";\n";
			}
		}
		if (k < cIf && nested && this.wt(W.StmtIf) > 0) {
			let text = indent + "if " + this.cond(0) + " {\n" + this.block(depth + 1, indent + "\t", inLoop, ret, inFn) + indent + "}";
			if (this.rng.chance(this.wt(W.StmtElse))) { text += " else {\n" + this.block(depth + 1, indent + "\t", inLoop, ret, inFn) + indent + "}"; }
			return text + "\n";
		}
		const available = (this.costCap - this.cost) / this.mult;
		const maxTrips = Math.min(this.tripMax, (available / (3 as int64)) as int32);
		if (k < cFor && nested && maxTrips > 0) {
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
		if (k < cMatch && this.wt(W.StmtMatch) > 0) {
			const m = this.matchLet(indent);
			if (m != "") { return m; }
		}
		if (k < cBreak && inLoop && this.wt(W.StmtBreak) > 0) {
			return indent + "if " + this.cond(0) + " { " + (this.rng.chance(50) ? "break" : "continue") + "; }\n";
		}
		if (inFn && this.wt(W.StmtReturn) > 0 && this.rng.chance(50)) {
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
		const savedBlock = this.blockId;
		this.blockCount++;
		this.blockId = this.blockCount;
		let out = "";
		for (let i = 0; i < n; i++) {
			if (this.nodesLeft == 0 || this.cost + this.mult > this.costCap) { break; }
			out += this.statement(depth, indent, inLoop, ret, inFn);
		}
		while (this.scope.length > saved) { this.scope.pop(); }
		while (this.ents.length > savedEnts) { this.ents.pop(); }
		this.blockId = savedBlock;
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
	if (plant == Plant.San) {
		return "@include(\"stdlib.h\")\n" +
			"extern function malloc(size: uint64): Ptr<void>;\n" +
			"extern function free(p: Ptr<void>): void;\n" +
			"function plantDelta(): int32 {\n" +
			"\tconst raw = malloc(8 as uint64);\n" +
			"\tfree(raw);\n" +
			"\tconst p = raw as Ptr<uint8>;\n" +
			"\tp[0] = 1 as uint8;\n" +
			"\treturn 0;\n" +
			"}\n";
	}
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
	g.w = f.w;

	let globals = "";
	for (let i = 0; i < f.globals; i++) {
		const t = g.pickTy();
		const name = "g" + String(i);
		globals += "let " + name + ": " + tyName(t) + " = " + g.literal(t) + ";\n";
		g.globals.push({ name: name, ty: t, writable: true });
	}

	let fns = "";
	for (let i = 0; i < f.funcs; i++) { fns += g.fn(i) + "\n"; }

	let top = "";
	for (let b = 0; b < f.top; b++) {
		g.scope = [];
		g.ents = [];
		g.cost = 0 as int64;
		g.costCap = FN_COST_CAP;
		g.mult = 1 as int64;
		g.atTop = true;
		top += g.block(0, "", false, Ty.Int32, false);
		g.atTop = false;
	}

	g.scope = [];
	g.ents = [];
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

	let head = "// smith seed=" + String(seed) + " features=" + f.format() + "\n";
	for (const d of g.directives) { head += d + "\n"; }
	return head + g.helperText + plantDecls(f.plant) + globals + "\n" + fns + top + entries + plantSite + prints;
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

function withWeights(text: string): Features {
	const parsed = Features.defaults().overlay(text);
	if (!parsed.ok) { unreachable; }
	return parsed.value;
}

function countOver(needle: string, seeds: int32, f: Features): int32 {
	let n = 0;
	for (let seed = 1; seed <= seeds; seed++) { n += countOf(generate(seed as uint64, f), needle); }
	return n;
}

test "a nested routine recurses at most its frame bound and may be named as a value" {
	const f = withWeights("fams=closure w.closure.routine=40");
	let routines = 0;
	let aliases = 0;
	let arrows = 0;
	for (let seed = 1; seed <= 20; seed++) {
		const text = generate(seed as uint64, f);
		for (const line of text.split("\n")) {
			const t = line.trim();
			if ((t.startsWith("function r") || (t.startsWith("const r") && t.contains(": int32): "))) && t.endsWith(" {") && line.startsWith("\t")) { routines++; }
			if (t.startsWith("const r") && t.endsWith(" => {")) { arrows++; }
			if (t.startsWith("if (q") && t.contains(" <= 0 || q") && !t.contains(" >= " + String(ROUTINE_FRAMES) + ") { return ")) { assert false; }
			if (t.startsWith("const k") && t.contains(" = r") && t.endsWith(";") && !t.contains("(")) { aliases++; }
		}
	}
	assert routines > 10;
	assert arrows > 3 && arrows < routines;
	assert aliases > 3;
	assert countOver(" == 2) { return ", 20, f) > 10;
}

test "a top-level block declares no function inside a block" {
	const f = withWeights("fams=closure w.closure.routine=40");
	let routines = 0;
	for (let seed = 1; seed <= 20; seed++) {
		const text = generate(seed as uint64, f);
		const at = text.indexOf("\nconsole.log(\"e");
		let inTop = false;
		for (const line of text.slice(0, at < 0 ? text.length : at).split("\n")) {
			if (line.startsWith("for (") || line.startsWith("if (")) { inTop = true; }
			if (line.startsWith("function ")) { inTop = false; }
			if (inTop && line.startsWith("\t") && line.trim().startsWith("function r")) { assert false; }
			if (inTop && line.trim().startsWith("const r") && line.endsWith(" => {")) { routines++; }
		}
	}
	assert routines > 0;
}

test "default weights keep the pinned stream" {
	const sizes = [23008, 14006, 27999, 14767];
	const closureSizes = [12836, 12148, 16450, 17808];
	const closure = withWeights("fams=closure top=0 w.closure.routine=0");
	for (let i = 0; i < 4; i++) {
		assert generate((i + 1) as uint64, withWeights("fams=closure,union,generic top=0 w.closure.routine=0")).replace(" top=0", "").replace(" w.closure.routine=0", "").byteLength == sizes[i];
		assert generate((i + 1) as uint64, closure).replace(" top=0", "").replace(" w.closure.routine=0", "").byteLength == closureSizes[i];
	}
}

test "the program head carries the non-default weights and nothing else" {
	const f = withWeights("w.expr.ternary=80");
	const text = generate(5 as uint64, f);
	assert text.startsWith("// smith seed=5 features=" + f.format() + "\n");
	assert text.contains(" plant=none w.expr.ternary=80\n");
}

test "a ternary-heavy vector multiplies ternaries and a zero weight removes them" {
	const base = withWeights("fams=none");
	const aimed = withWeights("fams=none w.expr.ternary=80 w.expr.leaf=10 w.expr.binary=4 w.expr.unary=2 w.expr.convert=2 w.expr.call=2");
	const none = withWeights("fams=none w.expr.ternary=0");
	assert countOver(" ? ", 12, aimed) > 5 * countOver(" ? ", 12, base);
	assert countOver(" ? ", 12, none) == 0;
}

test "a zero expression weight keeps its construct out of every expression" {
	const g = new Gen();
	g.tys = [Ty.Int32, Ty.Int8];
	g.exprMax = 5;
	g.fams = [Fam.Closure];
	g.fns = [{ name: "f0", ret: Ty.Int32, params: [], cost: 1 as int64 }];
	g.costCap = TOP_COST_CAP;
	g.w = withWeights("w.expr.ternary=0 w.expr.call=0 w.expr.unary=0 w.expr.convert=0 w.closure.iife=0").w;
	for (let seed = 1; seed <= 200; seed++) {
		g.rng = Rng.seeded(seed as uint64);
		g.nodesLeft = GEN_NODE_CAP;
		const text = g.expr(Ty.Int32, 0);
		assert !text.contains(" ? ") && !text.contains("f0(") && !text.contains("(~") && !text.contains("conv") && !text.contains("wrap") && !text.contains("safeNeg");
		assert !text.contains("(q");
	}
}

test "every signed width adds, subtracts, multiplies and negates through a guarded helper" {
	const g = new Gen();
	g.exprMax = 0;
	g.costCap = TOP_COST_CAP;
	for (const t of [Ty.Int8, Ty.Int16, Ty.Int32, Ty.Int64]) {
		g.tys = [t];
		for (let seed = 1; seed <= 100; seed++) {
			g.rng = Rng.seeded(seed as uint64);
			g.nodesLeft = GEN_NODE_CAP;
			const sum = g.binary(t, 0);
			assert sum.startsWith("safe") || (!sum.contains(" + ") && !sum.contains(" - ") && !sum.contains(" * "));
			const neg = g.unary(t, 0);
			assert neg.startsWith("safeNeg") || neg.startsWith("(~");
		}
	}
}

test "a zero binary weight leaves the fallbacks of call and convert out of binary" {
	const g = new Gen();
	g.tys = [Ty.Int32];
	g.exprMax = 5;
	g.costCap = TOP_COST_CAP;
	g.w = withWeights("w.expr.binary=0 w.expr.call=60").w;
	for (let seed = 1; seed <= 200; seed++) {
		g.rng = Rng.seeded(seed as uint64);
		g.nodesLeft = GEN_NODE_CAP;
		const text = g.expr(Ty.Int32, 0);
		assert !text.contains(" + ") && !text.contains(" * ") && !text.contains("safeAdd") && !text.contains("safeMul") && !text.contains("safeDiv");
	}
}

test "a zero statement weight keeps its statement out of every block" {
	const g = new Gen();
	g.tys = ALL_TYS;
	g.stmtMax = 6;
	g.depthMax = 4;
	g.exprMax = 3;
	g.tripMax = 4;
	g.costCap = TOP_COST_CAP;
	g.w = withWeights("w.stmt.for=0 w.stmt.match=0 w.stmt.compound=0 w.stmt.break=0").w;
	for (let seed = 1; seed <= 100; seed++) {
		g.rng = Rng.seeded(seed as uint64);
		g.nodesLeft = GEN_NODE_CAP;
		g.cost = 0 as int64;
		const text = g.block(0, "", false, Ty.Int32, true);
		assert !text.contains("for (") && !text.contains("match (") && !text.contains("+= ") && !text.contains("continue");
	}
}

test "family weights shape the choice among enabled families only" {
	const g = new Gen();
	g.tys = [Ty.Int32];
	g.exprMax = 3;
	g.costCap = TOP_COST_CAP;
	g.fams = [Fam.Closure, Fam.Union];
	g.w = withWeights("w.fam.closure=0 w.fam.generic=100").w;
	for (let seed = 1; seed <= 100; seed++) {
		g.rng = Rng.seeded(seed as uint64);
		g.nodesLeft = GEN_NODE_CAP;
		const text = g.famExpr(Ty.Int32, 0);
		assert !text.contains("BoxG") && !text.contains("(q");
	}
}

test "a weight cannot lift the cost bound of a routine" {
	const f = withWeights("w.expr.call=100 w.expr.fam=100 w.stmt.fam=100 w.stmt.let=100 w.stmt.for=100 w.stmt.if=100");
	for (let seed = 1; seed <= 12; seed++) {
		const g = new Gen();
		g.rng = Rng.seeded(seed as uint64);
		g.tys = [Ty.Int8, Ty.Int32];
		g.stmtMax = 32;
		g.depthMax = 8;
		g.exprMax = 8;
		g.tripMax = 64;
		g.fams = [Fam.Closure, Fam.Union, Fam.Generic];
		g.w = f.w;
		g.fn(0);
		g.fn(1);
		assert g.cost <= FN_COST_CAP;
		assert g.nodesLeft >= 0;
	}
}

test "the program head names its seed and full feature vector" {
	const f = Features.defaults();
	const text = generate(5 as uint64, f);
	assert text.startsWith("// smith seed=5 features=" + f.format() + "\n");
}

test "a san plant writes freed memory and leaves the printed result alone" {
	const f: Features = { ...Features.defaults(), plant: Plant.San };
	const text = generate(5 as uint64, f);
	assert text.contains("\tfree(raw);\n\tconst p = raw as Ptr<uint8>;\n\tp[0] = 1 as uint8;\n\treturn 0;\n");
	assert text.contains("plantDelta()");
	assert !text.contains("when (");
	const r = Features.defaults().overlay("plant=san");
	assert r.ok;
	if (r.ok) { assert r.value.plant == Plant.San && r.value.format().contains(" plant=san"); }
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
			assert !text.contains("PtS");
			assert !text.contains("ixI");
			assert !text.contains(": string = ");
			assert !text.contains("ownHooks");
			assert !text.contains("Vec<");
			assert !text.contains("CellQ");
		}
	}
}

test "the aggregate family alone reaches each of its shapes" {
	const f = withWeights("fams=agg types=int32,uint8 stmts=8 w.stmt.fam=80");
	const shapes = [": PtS", " = mkS", "{ ...s", ".n = s", "\tsetS", " = new CellC", ".p = ", ".put(", ".get()", "eqS", ".n.c", ".v = "];
	const seen: boolean[] = shapes.map((x: string): boolean => false);
	let alias = false;
	for (let seed = 1; seed < 41; seed++) {
		const text = generate(seed as uint64, f);
		for (let i = 0; i < shapes.length; i++) { if (text.contains(shapes[i])) { seen[i] = true; } }
		for (const line of text.split("\n")) {
			const t = line.trim();
			if (t.startsWith("const k") && t.contains(" = k") && t.endsWith(";") && t.length < 16) { alias = true; }
		}
	}
	for (let i = 0; i < shapes.length; i++) { assert seen[i]; }
	assert alias;
}

test "struct equality is never drawn for a float field" {
	const f = withWeights("fams=agg types=float64 w.agg.eq=100");
	for (let seed = 1; seed < 21; seed++) {
		assert countOf(generate(seed as uint64, f), "eqSFloat64(") <= 1;
	}
}

test "the aggregate weights choose between struct and class statements" {
	const structs = withWeights("fams=agg types=int32 w.agg.class=0 w.agg.alias=0 w.agg.poke=0");
	const cells = withWeights("fams=agg types=int32 w.agg.struct=0 w.agg.copy=0 w.agg.write=0 w.agg.ref=0");
	let s = 0;
	let k = 0;
	for (let seed = 1; seed < 21; seed++) {
		const a = generate(seed as uint64, structs);
		const b = generate(seed as uint64, cells);
		assert !a.contains("const k");
		assert !b.contains("let s");
		s += countOf(a, "let s");
		k += countOf(b, "const k");
	}
	assert s > 20 && k > 20;
}

test "the collection family alone reaches each of its shapes" {
	const f = withWeights("fams=coll types=int32,uint8 stmts=8 w.stmt.fam=80");
	const shapes = ["[ixI(", ".pop(); }", ".splice(ixI(", ".setLength(", ".fill(", ".reverse();", " = pushA", "[...a", ", ...a",
		".concat(", ").map(", "for (const x", "for (let j", "for (const [x", "let [l", ", ...r", "new Map<int32, ", "new Set<",
		" ?? ", ".delete(", ".add(", ".has(", ".includes(", ".indexOf(", ".join(\",\").length", "] = w"];
	const seen: boolean[] = shapes.map((x: string): boolean => false);
	for (let seed = 1; seed < 41; seed++) {
		const text = generate(seed as uint64, f);
		for (let i = 0; i < shapes.length; i++) { if (text.contains(shapes[i])) { seen[i] = true; } }
	}
	for (let i = 0; i < shapes.length; i++) { assert seen[i]; }
}

test "a family ternary is never narrowed by a raw cast" {
	const g = new Gen();
	g.rng = Rng.seeded(3 as uint64);
	g.tys = [Ty.Int32, Ty.Uint8];
	g.fams = [Fam.Coll];
	g.exprMax = 3;
	g.w = withWeights("w.expr.fam=100 w.coll.index=100").w;
	g.ents = [{ kind: EntKind.ArrayVar, name: "a0", ty: Ty.Int32, params: [], len: 0, cost: 0 as int64 }];
	let wrapped = 0;
	for (let i = 0; i < 200; i++) {
		g.costCap = TOP_COST_CAP;
		g.cost = 0 as int64;
		g.nodesLeft = GEN_NODE_CAP;
		const text = g.convert(Ty.Uint8, 0);
		assert !text.startsWith("((a0.length > 0 ? ");
		if (text.startsWith("wrapInt32ToUint8((a0.length > 0 ? ")) { wrapped++; }
	}
	assert wrapped > 10;
}

test "no ternary sits under arithmetic inside an else arm" {
	const g = new Gen();
	g.rng = Rng.seeded(5 as uint64);
	g.tys = [Ty.Int32, Ty.Uint8];
	g.fams = [Fam.Coll, Fam.Str, Fam.Own];
	g.exprMax = 4;
	g.w = withWeights("w.expr.ternary=60 w.expr.fam=60").w;
	g.ents = [
		{ kind: EntKind.ArrayVar, name: "a0", ty: Ty.Int32, params: [], len: 0, cost: 0 as int64 },
		{ kind: EntKind.HeldVar, name: "h1", ty: Ty.Int32, params: [], len: 0, cost: 0 as int64 },
	];
	let outside = 0;
	for (let i = 0; i < 300; i++) {
		g.costCap = TOP_COST_CAP;
		g.cost = 0 as int64;
		g.nodesLeft = GEN_NODE_CAP;
		g.elseArms = 1;
		assert !g.binary(Ty.Int32, 0).contains(" ? ");
		g.elseArms = 0;
		if (g.binary(Ty.Int32, 0).contains(" ? ")) { outside++; }
	}
	assert outside > 30;
}

test "a float element is never searched or kept in a Set" {
	const f = withWeights("fams=coll types=int32,float64 stmts=8 w.stmt.fam=80 w.coll.keyed=20 w.coll.size=20");
	let searched = 0;
	let floatDecls = 0;
	for (let seed = 1; seed < 21; seed++) {
		const text = generate(seed as uint64, f);
		assert !text.contains("new Set<float64>");
		const floats: string[] = [];
		for (const line of text.split("\n")) {
			if (line.startsWith("function ") || line.startsWith("}")) { floats.setLength(0); }
			const t = line.trim();
			const name = t.slice(t.indexOf(" ") + 1, t.indexOf(t.startsWith("let a") ? ":" : " ="));
			const source = t.slice(t.indexOf("= ") + 2, t.length - 1);
			if (t.startsWith("let a") && t.contains(": float64[] =")) {
				floats.push(name);
				floatDecls++;
			}
			if (t.startsWith("const a") && (t.contains("pushAFloat64(") || floats.includes(source))) { floats.push(name); }
			for (const a of floats) { assert !t.contains(a + ".includes(") && !t.contains(a + ".indexOf("); }
			if (t.contains(".includes(") || t.contains(".indexOf(")) { searched++; }
		}
	}
	assert searched > 10 && floatDecls > 10;
}

test "every for-of over a collection carries its trip bound" {
	const f = withWeights("fams=coll types=int32,uint8 stmts=8 w.stmt.fam=80 w.coll.loop=20");
	let loops = 0;
	for (let seed = 1; seed < 21; seed++) {
		const text = generate(seed as uint64, f);
		const forOf = countOf(text, "for (const x") + countOf(text, "for (const [x");
		assert forOf == countOf(text, "\tif (j");
		loops += forOf;
	}
	assert loops > 20;
}

test "the string family alone reaches each of its shapes" {
	const f = withWeights("fams=str types=int32,uint8 stmts=8 w.stmt.fam=80");
	const shapes = [".slice(", ".substring(", ".charAt(", "atS(", ".toUpperCase()", ".toLowerCase()", ".trim()", ".trimStart()",
		".trimEnd()", ".repeat(", ".padStart(", ".padEnd(", ".replace(", ".replaceAll(", ".split(", "String(", "${", ").length",
		".indexOf(\"", ".lastIndexOf(\"", "codeS(", " == ", " != ", " < ", " > ", ".includes(", ".startsWith(", ".endsWith(",
		" += (", "let s", " as string)", "\\n", "\\\"", "中"];
	const seen: boolean[] = shapes.map((x: string): boolean => false);
	for (let seed = 1; seed < 41; seed++) {
		const text = generate(seed as uint64, f);
		for (let i = 0; i < shapes.length; i++) { if (text.contains(shapes[i])) { seen[i] = true; } }
	}
	for (let i = 0; i < shapes.length; i++) { assert seen[i]; }
}

test "a string variable grows only by a bounded slice" {
	const f = withWeights("fams=str types=int32 stmts=8 w.stmt.fam=80 w.str.append=10 w.str.assign=10");
	let writes = 0;
	for (let seed = 1; seed < 21; seed++) {
		for (const line of generate(seed as uint64, f).split("\n")) {
			const t = line.trim();
			if (!t.startsWith("s")) { continue; }
			if (t.contains(" += (")) {
				assert t.endsWith(").slice(0, 8);");
				writes++;
			} else if (t.contains(" = (") && t.indexOf(" = (") < 6) {
				assert t.endsWith(").slice(0, 32);");
				writes++;
			}
		}
	}
	assert writes > 20;
}

test "the ownership family alone reaches each of its shapes" {
	const f = withWeights("fams=own types=int32,uint8 stmts=8 w.stmt.fam=80");
	const shapes = ["onDestroy(this o: OwnInt32)", "onCopy(this ref d: OwnUint8", ": OwnInt32 = mkO", ": OwnUint8 = o", " = move o", "= takeOInt32(move o",
		".push(move o", "\tbumpO", "(out o", ": OwnInt32[] = [o", ".push(o", ".tag.length", "].v : ", ".v"];
	const seen: boolean[] = shapes.map((x: string): boolean => false);
	let reassign = false;
	for (let seed = 1; seed < 41; seed++) {
		const text = generate(seed as uint64, f);
		for (let i = 0; i < shapes.length; i++) { if (text.contains(shapes[i])) { seen[i] = true; } }
		for (const line of text.split("\n")) {
			const t = line.trim();
			if (t.startsWith("o") && t.contains(" = o") && t.length < 16) { reassign = true; }
		}
	}
	for (let i = 0; i < shapes.length; i++) { assert seen[i]; }
	assert reassign;
}

function ownNameAt(text: string, at: int32): string {
	let end = at + 1;
	while (end < text.length && text.charCodeAt(end) >= 48 && text.charCodeAt(end) <= 57) { end++; }
	return end > at + 1 ? text.slice(at, end) : "";
}

function indentOf(line: string): int32 { return line.length - line.trimStart().length; }

test "a moved variable was declared in the moving block and is never named again" {
	const f = withWeights("fams=own types=int32,uint8 stmts=8 w.stmt.fam=80 w.own.move=6");
	let moves = 0;
	for (let seed = 1; seed < 41; seed++) {
		const lines = generate(seed as uint64, f).split("\n");
		for (let i = 0; i < lines.length; i++) {
			const at = lines[i].indexOf("move o");
			if (at < 0) { continue; }
			const name = ownNameAt(lines[i], at + 5);
			moves++;
			let declared = -1;
			for (let j = i - 1; j >= 0 && declared < 0; j--) {
				if (lines[j].trim().startsWith("let " + name + ":")) { declared = indentOf(lines[j]); }
			}
			assert declared == indentOf(lines[i]);
			for (let j = i + 1; j < lines.length && !lines[j].startsWith("}"); j++) {
				const k = lines[j].indexOf(name);
				assert k < 0 || ownNameAt(lines[j], k) != name;
			}
		}
	}
	assert moves > 20;
}

test "no ownership construct reaches a closure body" {
	const g = new Gen();
	g.rng = Rng.seeded(7 as uint64);
	g.tys = [Ty.Int32];
	g.fams = [Fam.Own];
	g.exprMax = 3;
	g.w = withWeights("w.expr.fam=100").w;
	g.ents = [
		{ kind: EntKind.OwnVar, name: "o0", ty: Ty.Int32, params: [], len: 0, cost: 0 as int64 },
		{ kind: EntKind.HeldVar, name: "h1", ty: Ty.Int32, params: [], len: 0, cost: 0 as int64 },
	];
	let outside = 0;
	for (let i = 0; i < 200; i++) {
		g.costCap = TOP_COST_CAP;
		g.cost = 0 as int64;
		g.nodesLeft = GEN_NODE_CAP;
		const body = g.lambda([Ty.Int32], Ty.Int32, 0, FN_COST_CAP).text;
		assert !body.contains("o0") && !body.contains("h1");
		const plain = g.expr(Ty.Int32, 0);
		if (plain.contains("o0") || plain.contains("h1")) { outside++; }
	}
	assert outside > 100;
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

test "the iter family alone reaches each of its shapes" {
	const f = withWeights("fams=iter types=int32,uint64,float64 stmts=8 w.stmt.fam=80 w.expr.fam=40");
	const shapes = ["\tfunction* y", "): Iterator<uint64> {", "): Iterator<float64> {", " => { a", "\t\tyield ", "\t\tfor (const x", "\tyield a",
		"for (const x", "{ break; }", ".next();", ".done || !r", ".value", "nthI(y", "lastI(y"];
	const seen: boolean[] = shapes.map((x: string): boolean => false);
	for (let seed = 1; seed < 41; seed++) {
		const text = generate(seed as uint64, f);
		for (let i = 0; i < shapes.length; i++) { if (text.contains(shapes[i])) { seen[i] = true; } }
	}
	for (let i = 0; i < shapes.length; i++) { assert seen[i]; }
}

test "a generator is declared only at a function's top level and its loop body holds no statement" {
	const f = withWeights("fams=iter stmts=8 w.stmt.fam=80 w.expr.fam=40 w.iter.decl=6");
	let gens = 0;
	for (let seed = 1; seed < 41; seed++) {
		const text = generate(seed as uint64, f);
		assert !text.contains("finally") && !text.contains("toItems");
		const lines = text.split("\n");
		for (let i = 0; i < lines.length; i++) {
			if (!lines[i].contains("function*")) { continue; }
			assert lines[i].startsWith("\tfunction* y");
			gens++;
			let j = i + 1;
			while (!lines[j].startsWith("\t\tfor (let i")) { j++; }
			for (j = j + 1; lines[j] != "\t\t}"; j++) {
				const t = lines[j].trim();
				assert t.startsWith("yield ") || t.startsWith("for (const x") || (t.contains(" = ") && !t.startsWith("let ") && !t.startsWith("const "));
			}
		}
	}
	assert gens > 20;
}

function seqFeatures(extra: string): Features {
	return withWeights("fams=seq stmts=8 w.stmt.fam=80 w.expr.fam=40 " + extra);
}

function gclsFeatures(extra: string): Features {
	return withWeights("fams=gcls stmts=8 w.stmt.fam=80 w.expr.fam=40 " + extra);
}

function textOver(f: Features, seeds: int32): string {
	let all = "";
	for (let seed = 1; seed <= seeds; seed++) { all += generate(seed as uint64, f); }
	return all;
}

function bothText(): string {
	return textOver(withWeights("fams=seq,gcls stmts=8 w.stmt.fam=80 w.expr.fam=40"), 60);
}

function reached(text: string, shapes: string[]): int32 {
	let missing = 0;
	for (const s of shapes) { if (!text.contains(s)) { missing++; } }
	return missing;
}

test "the seq family alone reaches each of its shapes" {
	const broad = textOver(seqFeatures("types=int32,uint8,float64"), 60);
	const shapes = ["pairT<", "swapT<", "firstQ<", "] = n", ": Vec<int32> = [", ": Vec<uint8> = v", "[] = v", ".slice(0, ", ").map((q",
		".length > 0 ? v", ".indexOf(", ".join(\",\").length", ".concat([", ".includes(",
		"spanAtInt32(v", "[0..", "[1..", "spanSetInt32(v", "readG<int32>(", "readG<uint8>(v",
		"[...v", ", ...v", "restVInt32(", "let [l", ", ...v", "pushQ<", "fillQ<Vec<", "fillQ<[", "headQ<",
		"takeQ<Vec<", ".set(move v", "for (const x", " of v", ".push(", ".pop();", ".splice(", ".fill(", ".setLength("];
	assert reached(broad, shapes) == 0;
	const same = textOver(seqFeatures("types=int32 w.seq.tuple=8 w.seq.ref=8"), 60);
	assert reached(same, ["swapQ<Vec<", "swapQ<[", "swapQ<int32>"]) == 0;
}

test "the gcls family alone reaches each of its shapes" {
	const broad = textOver(gclsFeatures("types=int32,uint8,float64"), 60);
	const shapes = ["new CellQ<", "idQ(", "idQ<CellQ<", ".map<", ".pairWith<", ".swap()", "bestQ<ItemQ<", "unwrapQ<", "unwrapQ<WrapQ<",
		"holdQ<", ".item", ".n)", "new StackQ<", ".top(", ".size()", "new ItemQ<", ".v.v", "new CellQ<CellQ<CellQ<", "fillQ<", "(out l",
		"roQ<CellQ<", "move z", "takeQ<Own", "swapQ<Own", ".drop();", ".set(", ".v = ", ".b = ", ".a = ", ".get().set(", ".get().get()",
		".key", "StackQ<Own", "CellQ<Own", ".swap().first()", ".first()"];
	assert reached(broad, shapes) == 0;
	const same = textOver(gclsFeatures("types=int32 w.gcls.decl=8 w.gcls.ref=8"), 60);
	assert reached(same, ["bestQ(", "swapQ<int32>(c", "swapQ<CellQ<"]) == 0;
}

test "a zero shape weight keeps its construct out of the program" {
	assert !textOver(seqFeatures("w.seq.borrow=0"), 30).contains("readG<");
	assert !textOver(seqFeatures("w.seq.span=0 w.seq.spanSet=0"), 30).contains("spanAtInt32(v");
	assert !textOver(seqFeatures("w.seq.span=0 w.seq.spanSet=0"), 30).contains("Set(v");
	const noBest = textOver(gclsFeatures("w.gcls.best=0"), 30);
	assert !noBest.contains("bestQ(") && !noBest.contains("bestQ<ItemQ<");
	const noOwn = textOver(gclsFeatures("w.gcls.own=0"), 30);
	assert !noOwn.contains("Own") && !noOwn.contains("ownHooks");
	assert textOver(gclsFeatures("w.gcls.own=8"), 30).contains("ownHooks");
}

test "a rest pattern puts one skip-raiser directive right after the head and cites its card" {
	let withRest = 0;
	let without = 0;
	for (let seed = 1; seed <= 30; seed++) {
		const text = generate(seed as uint64, seqFeatures("w.seq.rest=8"));
		const lines = text.split("\n");
		let rest = false;
		for (const line of lines) {
			const t = line.trim();
			if (t.startsWith("let [") && t.contains(", ...v")) { rest = true; }
		}
		assert countOf(text, "// @skip") == (rest ? 1 : 0);
		if (rest) {
			withRest++;
			assert lines[1].startsWith("// @skip-raiser: ");
			assert lines[1].contains("inbox/compiler/2026-10-17-raiser-has-no-host-bridge-for-msgenericarraypush");
		} else {
			without++;
		}
	}
	assert withRest > 10;
}

test "no directive is written unless a rest pattern asks for it and no program skips the JS lane" {
	assert !textOver(seqFeatures("w.seq.rest=0"), 40).contains("// @skip");
	assert !textOver(gclsFeatures(""), 40).contains("// @skip");
	assert !textOver(withWeights("w.fam.seq=0 w.fam.gcls=0"), 20).contains("// @skip");
	assert !bothText().contains("@skip-js");
}

test "a directive named twice is written once" {
	const g = new Gen();
	g.directive("// @skip-raiser: why");
	g.directive("// @skip-raiser: why");
	g.directive("// @skip-raiser: another");
	assert g.directives.length == 2;
}

test "a Vec push is refused once its length bound would pass the cap" {
	let pushed = false;
	for (const mult of [1000 as int64, 1 as int64]) {
		for (let seed = 1; seed <= 100; seed++) {
			const g = new Gen();
			g.rng = Rng.seeded(seed as uint64);
			g.tys = [Ty.Int32];
			g.exprMax = 1;
			g.costCap = TOP_COST_CAP;
			g.mult = mult;
			g.nodesLeft = GEN_NODE_CAP;
			g.ents = [{ kind: EntKind.VecVar, name: "v0", ty: Ty.Int32, params: [], len: 10, cost: 0 as int64 }];
			const text = g.seqVecEdit(Ty.Int32, "");
			if (text.contains(".push(")) { pushed = true; assert mult == (1 as int64); }
			assert g.ents[0].len <= SEQ_LEN_CAP;
			if (mult == (1 as int64) && text.contains(".push(")) { assert g.ents[0].len == 11; }
		}
	}
	assert pushed;
}

test "a moved Vec was declared in the moving block and is never named again" {
	const f = seqFeatures("types=int32,uint8 w.seq.move=8 w.seq.vec=6");
	let moves = 0;
	for (let seed = 1; seed < 41; seed++) {
		const lines = generate(seed as uint64, f).split("\n");
		for (let i = 0; i < lines.length; i++) {
			const at = lines[i].indexOf("move v");
			if (at < 0) { continue; }
			const name = ownNameAt(lines[i], at + 5);
			moves++;
			let declared = -1;
			for (let j = i - 1; j >= 0 && declared < 0; j--) {
				if (lines[j].trim().startsWith("let " + name + ":") || lines[j].contains("..." + name + "]")) { declared = indentOf(lines[j]); }
			}
			assert declared == indentOf(lines[i]);
			for (let j = i + 1; j < lines.length && !lines[j].startsWith("}"); j++) {
				const k = lines[j].indexOf(name);
				assert k < 0 || ownNameAt(lines[j], k) != name;
			}
		}
	}
	assert moves > 20;
}

test "no seq or gcls construct reaches a closure body" {
	const g = new Gen();
	g.rng = Rng.seeded(7 as uint64);
	g.tys = [Ty.Int32];
	g.fams = [Fam.Seq, Fam.Gcls];
	g.exprMax = 3;
	g.w = withWeights("w.expr.fam=100").w;
	const names = ["nq0", "vq1", "cq2", "zq4", "sq5", "kq6", "kq7"];
	g.ents = [
		{ kind: EntKind.TupleVar, name: "nq0", ty: Ty.Int32, params: [Ty.Int32, Ty.Int32], len: 2, cost: 0 as int64 },
		{ kind: EntKind.VecVar, name: "vq1", ty: Ty.Int32, params: [], len: 3, cost: 0 as int64 },
		{ kind: EntKind.CellVar, name: "cq2", ty: Ty.Int32, params: [], len: 0, cost: 0 as int64 },
		{ kind: EntKind.PairVar, name: "zq4", ty: Ty.Int32, params: [Ty.Int32, Ty.Int32], len: 0, cost: 0 as int64 },
		{ kind: EntKind.StackVar, name: "sq5", ty: Ty.Int32, params: [], len: 1, cost: 0 as int64 },
		{ kind: EntKind.ItemVar, name: "kq6", ty: Ty.Int32, params: [], len: 0, cost: 0 as int64 },
		{ kind: EntKind.ItemVar, name: "kq7", ty: Ty.Int32, params: [], len: 0, cost: 0 as int64 },
	];
	let outside = 0;
	for (let i = 0; i < 400; i++) {
		g.costCap = TOP_COST_CAP;
		g.cost = 0 as int64;
		g.nodesLeft = GEN_NODE_CAP;
		const body = g.lambda([Ty.Int32], Ty.Int32, 0, FN_COST_CAP).text;
		for (const n of names) { assert !body.contains(n); }
		const plain = g.expr(Ty.Int32, 0);
		for (const n of names) { if (plain.contains(n)) { outside++; } }
	}
	assert outside > 100;
}

test "a seq or gcls routine stays inside its cost bound" {
	const f = withWeights("w.expr.call=100 w.expr.fam=100 w.stmt.fam=100 w.stmt.let=100 w.stmt.for=100 w.stmt.if=100");
	for (let seed = 1; seed <= 12; seed++) {
		const g = new Gen();
		g.rng = Rng.seeded(seed as uint64);
		g.tys = [Ty.Int8, Ty.Int32];
		g.stmtMax = 32;
		g.depthMax = 8;
		g.exprMax = 8;
		g.tripMax = 64;
		g.fams = [Fam.Seq, Fam.Gcls];
		g.w = f.w;
		g.fn(0);
		g.fn(1);
		assert g.cost <= FN_COST_CAP;
		assert g.nodesLeft >= 0;
	}
}

test "no program nests a destructuring pattern, destructures an object or elides a slot" {
	const text = bothText();
	for (const shape of ["let [[", ", [l", "let {", "const {", "let [,", "[,", ", ,", "] = {"]) { assert !text.contains(shape); }
}

test "no program spreads a tuple, a Set or a Map, and every spread operand is a Vec" {
	const text = bothText();
	let at = text.indexOf("...");
	let spreads = 0;
	while (at >= 0) {
		spreads++;
		const next = text.slice(at + 3, at + 5);
		assert next == "xs" || (next.startsWith("v") && text.charCodeAt(at + 4) >= 48 && text.charCodeAt(at + 4) <= 57);
		at = text.indexOf("...", at + 3);
	}
	assert spreads > 20;
}

test "a spread argument always lands in the rest parameter of a variadic helper" {
	const text = textOver(seqFeatures("w.seq.spread=8"), 30);
	let calls = 0;
	for (const line of text.split("\n")) {
		if (!line.contains(" = restV") || line.startsWith("function")) { continue; }
		calls++;
		assert countOf(line, "...") == 1 && line.endsWith(");");
	}
	assert calls > 5;
}

test "a copied tuple is never written afterwards" {
	const f = withWeights("fams=seq types=int32 stmts=8 w.stmt.fam=80 w.seq.tuple=8 w.seq.tupleEdit=8 w.seq.ref=8");
	let copies = 0;
	for (let seed = 1; seed <= 40; seed++) {
		const lines = generate(seed as uint64, f).split("\n");
		for (let i = 0; i < lines.length; i++) {
			const t = lines[i].trim();
			const eq = t.lastIndexOf(" = n");
			if (!t.startsWith("let n") || !t.endsWith(";") || eq < 0 || t.contains("(")) { continue; }
			copies++;
			const names = [t.slice(4, t.indexOf(":")), t.slice(eq + 3, t.length - 1)];
			for (let j = i + 1; j < lines.length && !lines[j].startsWith("}"); j++) {
				const u = lines[j].trim();
				for (const name of names) {
					assert !(u.startsWith(name + "[") && u.contains("] = "));
					assert !u.contains("(out " + name + ",");
					assert !(u.contains("swapQ<[") && u.contains(name + ")")) && !(u.contains("swapQ<[") && u.contains("(" + name + ","));
				}
			}
		}
	}
	assert copies > 10;
}

test "no program names a shape that is parked behind an open compiler card" {
	const text = bothText();
	for (const shape of ["Record<", "[k: ", "{ [", "Cursor<", ".reverse()", ": readonly ", "setLength(-", "swapT(", "firstQ(", "pairT(", "readG(", "headQ(", "pushQ(", "fillQ(", "takeQ(", "roQ(", "unwrapQ(", "newWrapQ(", "holdQ("]) {
		assert !text.contains(shape);
	}
}

test "a move never feeds a constructor and a slice never feeds a Vec" {
	for (const line of bothText().split("\n")) {
		assert !(line.contains("new ") && line.contains("(move "));
		const rhs = line.slice(line.indexOf(" = ") + 3, line.length);
		const source = ownNameAt(rhs, 0);
		assert !(line.contains(": Vec<") && source != "" && rhs.startsWith(source + ".slice("));
	}
}

test "a borrow argument is always a variable, a field or an element" {
	const text = bothText();
	let at = text.indexOf("readG<");
	let borrows = 0;
	while (at >= 0) {
		const open = text.indexOf(">(", at);
		const c = text.charCodeAt(open + 2);
		if (text.charCodeAt(at - 1) != 32 || !text.slice(at - 9, at).startsWith("function")) {
			borrows++;
			assert c >= 97 && c <= 122;
		}
		at = text.indexOf("readG<", at + 6);
	}
	assert borrows > 20;
}

test "the enum family alone reaches each of its shapes" {
	const f = withWeights("fams=enum types=int32,uint8,float64 stmts=8 w.stmt.fam=80 w.expr.fam=40");
	const shapes = [
		"enum En", "selEn0", "mEn0",
		"BitSet<Fg", "bsFg0", ": BitSet<Fg0> = ", ".union(",
		"type Als", "alsId", "alsAt", "({ a: ", "({ v: ", "((q", ": Alc",
		"= distinct int32", "= distinct float64", "dsRankI([", "dsRankF([", ": DsI = ", ": DsF = ",
		"type Lt0 = \"", "cmpLt0(", "ifLt0(", "mwLt0(", "mxLt0(", ": Lt0 = ", " = nextLt0(",
		"type Dk0 =", "type Dm0 = match (kind: Kd0)", "type Db0 = match (ok: boolean)", "mkDk0(", ": Dk0 = ", ": Dm0 = ", ": Db0 = ",
		"): unknown {", ": unknown = mkCx(", "scoreCx(",
		"): never {", "const x: never = d;", "mustN(", "mustE(", "mustF(", "nvDk0(",
	];
	const floor = [1, 2, 2, 1, 2, 1, 1, 1, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 1, 1, 1, 1, 1, 2, 1, 1, 1, 1, 1, 2, 1, 1, 2, 2, 2, 2];
	assert shapes.length == floor.length;
	const seen: boolean[] = shapes.map((x: string): boolean => false);
	for (let seed = 1; seed < 61; seed++) {
		const text = generate(seed as uint64, f);
		for (let i = 0; i < shapes.length; i++) { if (countOf(text, shapes[i]) >= floor[i]) { seen[i] = true; } }
	}
	for (let i = 0; i < shapes.length; i++) { assert seen[i]; }
}

test "an enum never repeats a value, so no match repeats a case label" {
	for (let seed = 1; seed <= 200; seed++) {
		const g = new Gen();
		g.rng = Rng.seeded(seed as uint64);
		g.numericType(0, 0);
		const seen: int32[] = [];
		let expected = 0;
		for (const line of g.helperText.split("\n")) {
			if (!line.startsWith("\tM")) { continue; }
			const body = line.slice(0, line.length - 1);
			const eq = body.indexOf(" = ");
			const value = eq < 0 ? expected : parseInt(body.slice(eq + 3, body.length)) as int32;
			for (const v of seen) { assert v != value; }
			seen.push(value);
			expected = value + 1;
		}
		assert seen.length >= 2;
	}
}

test "match arms hold identical or disjoint pattern sets" {
	let helpers = 0;
	for (let seed = 1; seed <= 60; seed++) {
		const g = new Gen();
		g.rng = Rng.seeded(seed as uint64);
		g.tys = [Ty.Int32];
		const et = g.enumType(EShape.Numeric);
		g.matchHelper(et, Ty.Int32);
		helpers++;
		const sets: string[][] = [];
		for (const line of g.helperText.split("\n")) {
			if (!line.startsWith("\t\t") || !line.contains(" => ") || line.startsWith("\t\t_")) { continue; }
			let head = line.slice(2, line.indexOf(" => "));
			if (head.contains(" when ")) { head = head.slice(0, head.indexOf(" when ")); }
			sets.push(head.split(" | "));
		}
		for (const a of sets) {
			for (const b of sets) {
				let shared = 0;
				for (const x of a) { if (b.includes(x)) { shared++; } }
				assert shared == 0 || (shared == a.length && shared == b.length);
			}
		}
	}
	assert helpers == 60;
}

test "the enum family emits no shape a compiler card parks" {
	const f = withWeights("fams=enum stmts=8 w.stmt.fam=80 w.expr.fam=40");
	for (const set of LIT_SETS) {
		for (const lit of set.split(",")) { assert lit.length > 0 && !"-0123456789".includes(lit.slice(0, 1)); }
	}
	for (let seed = 1; seed < 41; seed++) {
		const text = generate(seed as uint64, f);
		assert !text.contains("distinct string") && !text.contains("Map<Ds") && !text.contains("Set<Ds");
		assert !text.contains("Lt0[]") && !text.contains("Lt1[]") && !text.contains("Lt2[]");
		assert !text.contains("assertNever") && countOf(text, ": never = ") == countOf(text, "const x: never = d;");
		assert countOf(text, "const x: never = d;") <= countOf(text, "function nvDk0(d: Dk0)");
		assert !text.contains("(d == e)") && !text.contains("(d != e)") && !text.contains("(d === e)") && !text.contains("d.length");
	}
	const g = new Gen();
	g.rng = Rng.seeded(1 as uint64);
	g.enumKit(EShape.Distinct, 0);
	g.enumKit(EShape.Distinct, 1);
	for (const line of g.helperText.split("\n")) {
		const bare = line.replaceAll("(x as int32)", "").replaceAll("(x as float64)", "");
		for (const op of [" + x", "x + ", " - x", "x - ", " * x", "x * ", " / x", "x / ", " % x", "x % "]) { assert !bare.contains(op); }
	}
}

test "a family at weight zero keeps the stream of the others" {
	for (const f of ALL_FAMS) {
		const others: string[] = [];
		for (const o of ALL_FAMS) { if (o != f) { others.push(famName(o)); } }
		const off = withWeights("w.fam." + famName(f) + "=0");
		const without = withWeights("fams=" + others.join(","));
		for (let seed = 1; seed <= 8; seed++) {
			const a = generate(seed as uint64, off);
			const b = generate(seed as uint64, without);
			assert a.slice(a.indexOf("\n"), a.length) == b.slice(b.indexOf("\n"), b.length);
		}
	}
}

test "the families added after own keep the seven-family stream at weight zero" {
	let zero = "";
	const first: string[] = [];
	for (const f of ALL_FAMS) {
		if (first.length < 7) { first.push(famName(f)); } else { zero += " w.fam." + famName(f) + "=0"; }
	}
	assert first[6] == "own";
	const off = withWeights(zero.trim());
	const without = withWeights("fams=" + first.join(","));
	for (let seed = 1; seed <= 20; seed++) {
		const a = generate(seed as uint64, off);
		const b = generate(seed as uint64, without);
		assert a.slice(a.indexOf("\n"), a.length) == b.slice(b.indexOf("\n"), b.length);
	}
}
