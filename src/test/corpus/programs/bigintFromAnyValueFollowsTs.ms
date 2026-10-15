// @xfail(raiser): bigint is not supported on the Raiser VM
// note: BigInt(x) takes every value TS takes: a string that is not an integer throws SyntaxError, a number that is not an integer (NaN and Infinity included) throws RangeError, booleans and every integer width convert exactly; the messages are node's.

function show(label: string, f: () => bigint): void {
	try {
		console.log(`${label} ok ${f()}`);
	} catch (e) {
		const kind = e instanceof RangeError
			? "RangeError"
			: e instanceof SyntaxError ? "SyntaxError" : "Error";
		console.log(`${label} ${kind} ${e.message}`);
	}
}

function f64(v: float64): float64 { return v; }
function byte(v: int32): char { return v as char; }

show("text", (): bigint => BigInt("12"));
show("bad text", (): bigint => BigInt("abc"));
show("fraction", (): bigint => BigInt(f64(1.5)));
show("negative", (): bigint => BigInt(f64(-2.0)));
show("negative zero", (): bigint => BigInt(f64(-0.0)));
show("large", (): bigint => BigInt(f64(1e21)));
show("nan", (): bigint => BigInt(f64(0.0) / f64(0.0)));
show("infinity", (): bigint => BigInt(f64(1.0) / f64(0.0)));
show("-infinity", (): bigint => BigInt(f64(-1.0) / f64(0.0)));
show("sum", (): bigint => BigInt(f64(0.1) + f64(0.2)));
show("true", (): bigint => BigInt(true));
show("false", (): bigint => BigInt(false));
show("int8", (): bigint => BigInt(-8 as int8));
show("uint8", (): bigint => BigInt(200 as uint8));
show("int16", (): bigint => BigInt(-300 as int16));
show("uint16", (): bigint => BigInt(65535 as uint16));
show("int32", (): bigint => BigInt(-7 as int32));
show("uint32", (): bigint => BigInt(4294967295 as uint32));
show("int64", (): bigint => BigInt(-9223372036854775807 as int64));
show("uint64", (): bigint => BigInt(18446744073709551615 as uint64));
show("char", (): bigint => BigInt(byte(66)));
show("bigint", (): bigint => BigInt(5n));
show("literal", (): bigint => BigInt(5));
