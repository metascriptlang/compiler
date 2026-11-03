// @stdout: div RangeError Division by zero
// @stdout: pow negative RangeError Exponent must be non-negative
// @xfail(js): node throws its own RangeError, which the JS prelude's RangeError class does not match (inbox 2026-10-13-js-thrown-error-is-not-a-js-error), and words the negative exponent differently
// @xfail(esm): the same JS gap as @xfail(js)
// note: division or remainder by zero, a negative exponent and a negative asIntN/asUintN width throw a catchable RangeError on C and the Raiser, as JS does; C used to abort with exit 134.

function show(label: string, f: () => bigint): void {
	try {
		console.log(`${label} ok ${f()}`);
	} catch (e) {
		const kind = e instanceof RangeError ? "RangeError" : "Error";
		console.log(`${label} ${kind} ${e.message}`);
	}
}

function zero(): bigint { return 0n; }

show("div", (): bigint => 5n / zero());
show("mod", (): bigint => -5n % zero());
show("div assign", (): bigint => {
	let x = 7n;
	x /= zero();
	return x;
});
show("mod assign", (): bigint => {
	let x = 7n;
	x %= zero();
	return x;
});
show("pow negative", (): bigint => 2n ** (zero() - 1n));
show("asUintN negative", (): bigint => BigInt.asUintN(-1, 1n));
show("asIntN negative", (): bigint => BigInt.asIntN(-1, 1n));
show("div ok", (): bigint => -7n / 2n);
show("mod ok", (): bigint => -7n % 2n);
show("pow zero", (): bigint => 3n ** zero());
console.log("after");
