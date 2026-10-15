// @stdout: fraction RangeError The number 1.5 cannot be converted to a BigInt because it is not an integer
// @xfail(raiser): bigint is not supported on the Raiser VM
// note: a number that is not an integer (NaN and Infinity included) converted with `as bigint` throws the catchable RangeError that BigInt(x) throws, with node's message, on C and JS; C used to abort with exit 134.

function show(label: string, f: () => bigint): void {
	try {
		console.log(`${label} ok ${f()}`);
	} catch (e) {
		const kind = e instanceof RangeError ? "RangeError" : "Error";
		console.log(`${label} ${kind} ${e.message}`);
	}
}

function f64(v: float64): float64 { return v; }
function f32(v: float32): float32 { return v; }
function num(v: number): number { return v; }

show("whole", (): bigint => f64(2.0) as bigint);
show("negative zero", (): bigint => f64(-0.0) as bigint);
show("large", (): bigint => f64(1e21) as bigint);
show("fraction", (): bigint => f64(1.5) as bigint);
show("negative fraction", (): bigint => f64(-0.5) as bigint);
show("float32 fraction", (): bigint => f32(2.25) as bigint);
show("number fraction", (): bigint => num(0.1) as bigint);
show("nan", (): bigint => (f64(0.0) / f64(0.0)) as bigint);
show("infinity", (): bigint => (f64(1.0) / f64(0.0)) as bigint);
show("-infinity", (): bigint => (f64(-1.0) / f64(0.0)) as bigint);
show("BigInt alike", (): bigint => BigInt(f64(1.5)));
