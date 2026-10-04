import { Rng, seeded } from "./rng";
import { ALL_TYS, Features, Plant, Ty, tyName, format } from "./features";

const FN_COST_CAP: int64 = 20000 as int64;
const TOP_COST_CAP: int64 = 200000 as int64;

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

	pickTy(): Ty { return this.tys[this.rng.below(this.tys.length)]; }

	pickOp(ops: string[]): string { return ops[this.rng.below(ops.length)]; }

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
		let from = this.pickTy();
		while (from == t) { from = this.pickTy(); }
		const a = this.expr(from, depth + 1);
		const checkedAtCompileTime = this.shape != Shape.Other;
		if (checkedAtCompileTime && isSigned(from) && !isSigned(t) && !isFloat(t)) { return this.wrapHelper(from, t) + "(" + a + ")"; }
		if (fitsRaw(from, t)) { return "(" + a + " as " + tyName(t) + ")"; }
		return this.convHelper(from, t) + "(" + a + ")";
	}

	cond(depth: int32): string {
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
		const added = this.mult * f.cost + (1 as int64);
		if (this.cost + added > this.costCap) { return ""; }
		this.cost = this.cost + added;
		let args = "";
		for (const p of f.params) {
			const a = this.expr(p, depth + 1);
			args = args == "" ? a : args + ", " + a;
		}
		return f.name + "(" + args + ")";
	}

	expr(t: Ty, depth: int32): string {
		if (depth >= this.exprMax) { return this.leaf(t); }
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
		this.cost = this.cost + this.mult;
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
		if (k < 82 && nested) {
			const name = "i" + String(this.loopCount);
			this.loopCount = this.loopCount + 1;
			const trips = this.rng.between(1, this.tripMax);
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
		const n = this.rng.between(1, this.stmtMax);
		let out = "";
		for (let i = 0; i < n; i++) { out += this.statement(depth, indent, inLoop, ret, inFn); }
		while (this.scope.length > saved) { this.scope.pop(); }
		return out;
	}

	fn(index: int32): string {
		const ret = this.pickTy();
		const params: Ty[] = [];
		const paramCount = this.rng.below(4);
		let sig = "";
		this.scope = [];
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
