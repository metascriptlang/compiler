// @stdout: math number boolean done

// Math is a namespace class carrying static extensions; Number and Boolean are
// callable names. On C the calls bind to libm and to bodies here; on JS every
// one of them emits the native global inline, so both backends must agree
// digit for digit.

function check(name: string, ok: boolean): boolean {
	if (!ok) { console.log("FAIL " + name); }
	return ok;
}

function rounding(): boolean {
	let ok = check("floor", Math.floor(3.7) === 3.0);
	ok = check("floor negative", Math.floor(-3.2) === -4.0) && ok;
	ok = check("ceil", Math.ceil(3.2) === 4.0) && ok;
	ok = check("trunc", Math.trunc(4.9) === 4.0) && ok;
	ok = check("trunc negative", Math.trunc(-4.9) === -4.0) && ok;
	// C rounds half away from zero, JS toward +Infinity: this cell is the guard.
	ok = check("round half up", Math.round(2.5) === 3.0) && ok;
	ok = check("round negative half", Math.round(-2.5) === -2.0) && ok;
	return ok;
}

function arithmetic(): boolean {
	let ok = check("abs", Math.abs(-5.0) === 5.0);
	ok = check("abs zero", Math.abs(-0.0) === 0.0) && ok;
	ok = check("sqrt", Math.sqrt(16.0) === 4.0) && ok;
	ok = check("cbrt", Math.cbrt(27.0) === 3.0) && ok;
	ok = check("pow", Math.pow(2.0, 10.0) === 1024.0) && ok;
	ok = check("hypot", Math.hypot(3.0, 4.0) === 5.0) && ok;
	ok = check("min", Math.min(3.0, 7.0) === 3.0) && ok;
	ok = check("max", Math.max(3.0, 7.0) === 7.0) && ok;
	ok = check("sign positive", Math.sign(9.0) === 1.0) && ok;
	ok = check("sign negative", Math.sign(-9.0) === -1.0) && ok;
	ok = check("sign zero", Math.sign(0.0) === 0.0) && ok;
	ok = check("exp zero", Math.exp(0.0) === 1.0) && ok;
	ok = check("log one", Math.log(1.0) === 0.0) && ok;
	ok = check("log2", Math.log2(8.0) === 3.0) && ok;
	ok = check("log10", Math.log10(1000.0) === 3.0) && ok;
	return ok;
}

function trigonometry(): boolean {
	let ok = check("sin zero", Math.sin(0.0) === 0.0);
	ok = check("cos zero", Math.cos(0.0) === 1.0) && ok;
	ok = check("tan zero", Math.tan(0.0) === 0.0) && ok;
	ok = check("asin zero", Math.asin(0.0) === 0.0) && ok;
	ok = check("atan zero", Math.atan(0.0) === 0.0) && ok;
	ok = check("atan2 axis", Math.atan2(0.0, 1.0) === 0.0) && ok;
	ok = check("sinh zero", Math.sinh(0.0) === 0.0) && ok;
	ok = check("cosh zero", Math.cosh(0.0) === 1.0) && ok;
	ok = check("tanh zero", Math.tanh(0.0) === 0.0) && ok;
	return ok;
}

function numberSurface(): boolean {
	let ok = check("Number from string", Number("42.5") === 42.5);
	ok = check("Number negative", Number("-7") === -7.0) && ok;
	ok = check("Number from true", Number(true) === 1.0) && ok;
	ok = check("Number from false", Number(false) === 0.0) && ok;
	ok = check("isInteger true", Number.isInteger(4.0)) && ok;
	ok = check("isInteger false", !Number.isInteger(4.5)) && ok;
	ok = check("isFinite true", Number.isFinite(1.0)) && ok;
	ok = check("isNaN false", !Number.isNaN(0.0)) && ok;
	ok = check("isSafeInteger true", Number.isSafeInteger(9007199254740991.0)) && ok;
	ok = check("isSafeInteger false", !Number.isSafeInteger(9007199254740993.0)) && ok;
	return ok;
}

function booleanSurface(): boolean {
	let ok = check("empty string falsy", !Boolean(""));
	ok = check("string truthy", Boolean("x")) && ok;
	ok = check("zero falsy", !Boolean(0.0)) && ok;
	ok = check("number truthy", Boolean(3.5)) && ok;
	ok = check("bool identity", Boolean(true)) && ok;
	return ok;
}

// Static fields cross a module boundary through an extern declaration on C and
// a class static on JS — two different carriers that must agree bit for bit.
function constants(): boolean {
	let ok = check("PI", Math.PI === 3.141592653589793);
	ok = check("E", Math.E === 2.718281828459045) && ok;
	ok = check("SQRT2", Math.SQRT2 === 1.4142135623730951) && ok;
	ok = check("LN2", Math.LN2 === 0.6931471805599453) && ok;
	ok = check("PI floors to 3", Math.floor(Math.PI) === 3.0) && ok;
	return ok;
}

function main(): int32 {
	let ok = rounding();
	ok = constants() && ok;
	ok = arithmetic() && ok;
	ok = trigonometry() && ok;
	ok = numberSurface() && ok;
	ok = booleanSurface() && ok;
	if (!ok) { return 1; }
	console.log("math number boolean done");
	return 0;
}

const rc = main();
if (rc !== 0) { process.exit(rc); }
