// @stdout: number statics done

// Number is a callable name that also carries static constants — the
// statics-only class in the number prelude merges onto the function symbol.
// On C the constants are module globals initialized in DatInit (literals)
// and Init (folded arithmetic for the non-finite trio); on JS reads emit as
// native member accesses on the Number global. Both backends must agree
// digit for digit, including the Infinity/NaN spellings.

function check(name: string, ok: boolean): boolean {
	if (!ok) { console.log("FAIL " + name); }
	return ok;
}

function safeIntegerBounds(): boolean {
	let ok = check("max safe", Number.MAX_SAFE_INTEGER == 9007199254740991.0);
	ok = check("min safe", Number.MIN_SAFE_INTEGER == -9007199254740991.0) && ok;
	ok = check("max safe is safe", Number.isSafeInteger(Number.MAX_SAFE_INTEGER)) && ok;
	ok = check("max safe plus one is not", !Number.isSafeInteger(Number.MAX_SAFE_INTEGER + 1.0)) && ok;
	ok = check("max safe plus five", Number.MAX_SAFE_INTEGER + 5.0 == 9007199254740996.0) && ok;
	return ok;
}

function doubleLimits(): boolean {
	let ok = check("max value", Number.MAX_VALUE == 1.7976931348623157e308);
	ok = check("min value", Number.MIN_VALUE == 5e-324) && ok;
	ok = check("epsilon", Number.EPSILON == 2.220446049250313e-16) && ok;
	ok = check("epsilon gap", 1.0 + Number.EPSILON != 1.0) && ok;
	ok = check("below epsilon folds", 1.0 + Number.EPSILON / 2.0 == 1.0) && ok;
	return ok;
}

function nonFinite(): boolean {
	let ok = check("pinf above max", Number.POSITIVE_INFINITY > Number.MAX_VALUE);
	ok = check("ninf below min", Number.NEGATIVE_INFINITY < -Number.MAX_VALUE) && ok;
	ok = check("nan not itself", Number.NaN != Number.NaN) && ok;
	ok = check("inf minus inf is nan", Number.POSITIVE_INFINITY - Number.POSITIVE_INFINITY != Number.POSITIVE_INFINITY - Number.POSITIVE_INFINITY) && ok;
	ok = check("max times two overflows", Number.MAX_VALUE * 2.0 == Number.POSITIVE_INFINITY) && ok;
	return ok;
}

function spellings(): boolean {
	console.log("pinf=" + Number.POSITIVE_INFINITY.toString());
	console.log("ninf=" + Number.NEGATIVE_INFINITY.toString());
	console.log("nan=" + Number.NaN.toString());
	console.log("maxv=" + Number.MAX_VALUE.toString());
	console.log("minv=" + Number.MIN_VALUE.toString());
	console.log("eps=" + Number.EPSILON.toString());
	console.log("maxs=" + Number.MAX_SAFE_INTEGER.toString());
	return true;
}

function callableStillWorks(): boolean {
	let ok = check("convert string", Number("123.5") == 123.5);
	ok = check("convert boolean", Number(true) == 1.0) && ok;
	ok = check("is integer", Number.isInteger(5.0)) && ok;
	ok = check("not integer", !Number.isInteger(5.5)) && ok;
	ok = check("is safe", Number.isSafeInteger(1.0)) && ok;
	ok = check("not safe", !Number.isSafeInteger(Number.POSITIVE_INFINITY)) && ok;
	ok = check("is finite", Number.isFinite(1.0)) && ok;
	ok = check("inf not finite", !Number.isFinite(Number.POSITIVE_INFINITY)) && ok;
	ok = check("nan not finite", !Number.isFinite(Number.NaN)) && ok;
	ok = check("math pi unaffected", Math.PI == 3.141592653589793) && ok;
	return ok;
}

function main(): int32 {
	let ok = safeIntegerBounds();
	ok = doubleLimits() && ok;
	ok = nonFinite() && ok;
	ok = spellings() && ok;
	ok = callableStillWorks() && ok;
	if (!ok) { return 1; }
	console.log("number statics done");
	return 0;
}

main();
