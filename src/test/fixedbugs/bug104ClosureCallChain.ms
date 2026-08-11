// bug104 — a closure produced by an expression could not be called in place
//
// Symptom:    `makeAdder(1)(2)` failed to build on the C backend with `called
//             object type 'msClosure' is not a function or function pointer`.
//             The ternary and array-access callee shapes failed identically.
//             JS was unaffected — it emits `callee(args)` for every shape.
// Root cause: closure-call dispatch was gated on the callee's NodeKind, spread
//             over three passes at different pipeline stages. A callee that only
//             exists AFTER lowering was owned by none of them: `rvalueLower`
//             hoists a call result into `$tmp`, `conditionalExprLower` a ternary
//             into `$tern`, and the checker had already run on the pre-hoist AST
//             where the callee was still a CallExpr.
// Fix:        `closureCallMarker` (last native pass, the reference's genAsgnCall
//             position) decides on the callee type's callConv alone, and
//             `createIterator` builds its `next` field with `createClosureType`
//             so that flag tells the truth.
//
// Sibling: corpus program 305-closureCallChain pins the same shapes as a real
// binary across every lane; this file pins them inside the test tier.

type Adder104 = (n: int32) => int32;

interface Holder104 {
	fn: Adder104;
}

function makeAdder104(k: int32): Adder104 {
	return (n: int32): int32 => n + k;
}

function pickAdder104(useFirst: boolean, a: Adder104, b: Adder104): Adder104 {
	if (useFirst) return a;
	return b;
}

test "bug104: a closure returned by a call is callable in place" {
	assert makeAdder104(1)(2) === 3;
}

test "bug104: a closure selected by a ternary is callable in place" {
	const flag = true;
	assert (flag ? makeAdder104(100) : makeAdder104(200))(5) === 105;
}

test "bug104: a closure read out of an array is callable in place" {
	const table: Adder104[] = [makeAdder104(1000), makeAdder104(2000)];
	assert table[0](7) === 1007;
	assert table[1](7) === 2007;
}

test "bug104: a closure held in a field is callable in place" {
	const holder: Holder104 = { fn: makeAdder104(30000) };
	assert holder.fn(7) === 30007;
}

test "bug104: a closure relayed through a parameter is callable in place" {
	assert pickAdder104(true, makeAdder104(3), makeAdder104(4))(1) === 4;
	assert pickAdder104(false, makeAdder104(3), makeAdder104(4))(1) === 5;
}

test "bug104: a for-of generator still steps through its iterator" {
	// createIterator's `next` field is the type that had to stop lying; a
	// generator drives it through the same dispatch.
	let total: int32 = 0;
	for (const v of gen104()) {
		total = total + v;
	}
	assert total === 6;
}

function* gen104(): Iterator<int32> {
	yield 1;
	yield 2;
	yield 3;
}
