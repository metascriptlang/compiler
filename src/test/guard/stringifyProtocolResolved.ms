// nim-guard: a compiler-inserted stringify call is RESOLVED, like any other call
//
// INVARIANT (Nim): the stringification a call site needs is inserted during
//   semantic analysis, not after it. `echo x` matches `varargs[typed, $]` and
//   sigmatch forwards the argument through the converter (`localConvMatch`,
//   sigmatch.nim:2596; `implicitConv` :2179), so the `$` call it plants is
//   produced BY overload resolution and carries the winning symbol. Nim has no
//   backend pass that plants a call and hopes a later pass can bind it.
// NIM-REF: §1 "Implicit stringification is inserted at check time".
//
// WHAT IT CATCHES: MS used to plant `x.toString()` in stringConcatFlatten — a
//   post-checker, C-only transform. The synthesized MemberExpr never passed
//   through the checker, so it carried no resolvedSym and no NF_ExtCall, and
//   extensionMethodLower (which keys off exactly those) skipped it. C codegen
//   then printed a struct member call: `a->toString()` -> clang "no member named
//   'toString' in 'struct A'". Primitives escaped (builtinLower binds them by
//   type) and an explicitly written `a.toString()` escaped (the checker bound
//   it), so only compiler-INSERTED stringification of a user type was broken.
//
// RED MEANS: implicit stringification stopped resolving through the normal call
//   machinery. This probe fails to BUILD (clang: no member named 'toString') or
//   throws on a wrong value. Run /trace-nim on the concat path in
//   checker/checkExprPass.ms + transform/coercion/stringConcatFlatten.ms.
//
// No RC balance directive — the signal is build-failure / wrong-value-throw.
// Run by src/test/guard/run.sh with -DMS_DRC_LEDGER (drc + orc).

class Money {
	amount: number;
	constructor(a: number) { this.amount = a; }
	toString(): string { return "$" + this.amount.toString(); }
}

class Point {
	x: number;
	y: number;
	constructor(x: number, y: number) { this.x = x; this.y = y; }
}

// Extension-declared stringify: same protocol, different declaration site.
function toString(this p: Point): string { return "(" + p.x.toString() + "," + p.y.toString() + ")"; }

interface Tag { name: string; }

function toString(this t: Tag): string { return "#" + t.name; }

// A stringify whose own body concats user objects — the synthesis must nest.
class Pair {
	a: Money;
	b: Money;
	constructor(x: Money, y: Money) { this.a = x; this.b = y; }
	toString(): string { return "<" + this.a + "|" + this.b + ">"; }
}

let receiverEvals = 0;

function nextMoney(): Money {
	receiverEvals = receiverEvals + 1;
	return new Money(9);
}

function viaGeneric<T>(x: T): string { return "g=" + x; }

function main(): void {
	const m = new Money(7);
	const p = new Point(1, 2);
	const t: Tag = { name: "hot" };

	// Two-part concat — the shape that reaches msStringConcat.
	const twoPart = "m=" + m;
	if (twoPart !== "m=$7") { throw "GUARD RED: 2-part concat of a class method receiver = " + twoPart; }

	// Three-plus parts — the shape that reaches msStringConcatArr.
	const manyPart = "m=" + m + " p=" + p;
	if (manyPart !== "m=$7 p=(1,2)") { throw "GUARD RED: N-part concat with an extension receiver = " + manyPart; }

	// Extension on an interface type.
	const ifacePart = "t=" + t;
	if (ifacePart !== "t=#hot") { throw "GUARD RED: concat of an interface extension receiver = " + ifacePart; }

	// Template literal desugars to the same concat path.
	const tmpl = `m=${m} t=${t}`;
	if (tmpl !== "m=$7 t=#hot") { throw "GUARD RED: template literal interpolation = " + tmpl; }

	// Compound assign: the RHS needs the same insertion before msStringAppend.
	let acc = "p=";
	acc += p;
	if (acc !== "p=(1,2)") { throw "GUARD RED: '+=' of a user type = " + acc; }

	// A numeric subtree inside a concat must still evaluate numerically first.
	const n = 21;
	const atomic = "n=" + (n + 1) + "!";
	if (atomic !== "n=22!") { throw "GUARD RED: numeric subtree split by the concat path = " + atomic; }

	// The receiver is the operand node itself — planting the call must not
	// duplicate it, or a side-effecting receiver runs twice.
	const once = "once=" + nextMoney();
	if (once !== "once=$9") { throw "GUARD RED: call-expression receiver = " + once; }
	if (receiverEvals !== 1) { throw "GUARD RED: receiver evaluated " + receiverEvals.toString() + " times, expected 1"; }

	// Rvalue receiver: no named local exists to take the address of (the shape
	// that broke the asBytes bridge, NIM-REF "zero-copy bridge ownership").
	const rvalue = "rv=" + new Money(3);
	if (rvalue !== "rv=$3") { throw "GUARD RED: rvalue receiver = " + rvalue; }

	// User type on the LEFT of the concat.
	const leftSide = m + " end";
	if (leftSide !== "$7 end") { throw "GUARD RED: user type as left operand = " + leftSide; }

	// A stringify body that concats user objects itself.
	const nested = "n=" + new Pair(new Money(1), new Money(2));
	if (nested !== "n=<$1|$2>") { throw "GUARD RED: nested synthesis inside toString = " + nested; }

	// Repeated receiver in one chain, and accumulation through '+=' in a loop.
	const repeat = "" + m + m;
	if (repeat !== "$7$7") { throw "GUARD RED: repeated receiver in one chain = " + repeat; }
	let loop = "";
	for (let i = 0; i < 3; i = i + 1) { loop += new Money(i); }
	if (loop !== "$0$1$2") { throw "GUARD RED: '+=' accumulation in a loop = " + loop; }

	// Through a generic parameter — the operand's type is only a struct after
	// instantiation.
	const generic = viaGeneric(m);
	if (generic !== "g=$7") { throw "GUARD RED: concat through a generic parameter = " + generic; }

	console.log("stringifyProtocolResolved ok");
}

main();
