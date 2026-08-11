// Parity program — invoking a closure that an EXPRESSION produced, in place.
//
// The call dispatch (direct call vs closure call) must be decided by the
// callee's TYPE, never by its syntactic shape. Every arm below is the same
// closure reached through a different expression form; if dispatch is gated on
// node kind, the arms whose callee is not a plain identifier emit a raw C call
// on an msClosure struct and the lane fails to build.
//
// Sibling coverage: 300-closureBasics pins capture/escape/curry through
// intermediate bindings — the shapes here deliberately skip the binding.

type IntFn = (n: int32) => int32;

interface Holder {
	fn: IntFn;
}

function makeAdder(k: int32): IntFn {
	return (n: int32): int32 => n + k;
}

function pickAdder(useFirst: boolean, a: IntFn, b: IntFn): IntFn {
	if (useFirst) return a;
	return b;
}

function main(): void {
	// callee = CallExpr — the returned closure is invoked without ever landing
	// in a named local.
	console.log("chained=" + makeAdder(1)(2).toString());
	console.log("chainedTwice=" + (makeAdder(10)(5) + makeAdder(20)(5)).toString());

	// callee = Identifier (the shape that always worked — regression pin).
	const bound = makeAdder(1);
	console.log("bound=" + bound(2).toString());

	// callee = ConditionalExpr.
	const flag = true;
	console.log("ternaryTrue=" + (flag ? makeAdder(100) : makeAdder(200))(5).toString());
	console.log("ternaryFalse=" + (!flag ? makeAdder(100) : makeAdder(200))(5).toString());

	// callee = ArrayAccess.
	const table: IntFn[] = [makeAdder(1000), makeAdder(2000)];
	console.log("array0=" + table[0](7).toString());
	console.log("array1=" + table[1](7).toString());

	// callee = MemberExpr on a heap object.
	const holder: Holder = { fn: makeAdder(30000) };
	console.log("field=" + holder.fn(7).toString());

	// callee = CallExpr returning through a parameter, so the closure crosses a
	// function boundary before being invoked.
	console.log("relayed=" + pickAdder(true, makeAdder(3), makeAdder(4))(1).toString());
	console.log("relayedElse=" + pickAdder(false, makeAdder(3), makeAdder(4))(1).toString());

	// Non-capturing closure — the emitted dispatch branches on a null env, so
	// the env-less side needs its own arm.
	const plain: IntFn = (n: int32): int32 => n * 2;
	const pickPlain = (): IntFn => plain;
	console.log("noEnv=" + pickPlain()(21).toString());

	// Chained through a loop so the closure is rebuilt and dropped repeatedly.
	let total: int32 = 0;
	for (let i = 0; i < 5; i += 1) {
		total = total + makeAdder(i)(i);
	}
	console.log("loopTotal=" + total.toString());
}
main();
