// @maxrss: 30
// @stdout: op-chain acc=105
// note: Locks NESTED/CHAINED overloaded operators (a*b+c, a+b+c, c+a*b, a*b*c+a, -(a+b), v+=a*b). operatorLower.makeExtOpCall built the replacement CallExpr with no nodeType; the bottom-up walker then made a parent operator's resolveType return null → it skipped lowering → raw C operator on structs → clang 'invalid operands'. Fix: the lowered call carries its operator return type. Separate from NRVO (this is transform/operatorLower, not codegen out-param). Reference (Nim) resolves operators in sem and types the call at once, so it can't drop the type.

// Regression: NESTED/CHAINED overloaded operators. A binary/unary operator whose
// operand is itself an overloaded-operator call (a*b + c, a+b+c, c+a*b, a*b*c, -(a+b),
// v += a*b) must lower to a function call. operatorLower's makeExtOpCall built the
// replacement CallExpr WITHOUT a nodeType, so when the walker lowered bottom-up the
// parent operator's resolveType saw null and bailed → raw C `+`/`*` on structs →
// clang "invalid operands". Fix: the lowered call carries its return type. Reference
// (Nim) has no such bug: operators resolve in sem, the resolved call is typed at once.

struct V { x: float32; y: float32; }

function `*`(this a: V, b: V): V { return { x: a.x * b.x, y: a.y * b.y }; }
function `+`(this a: V, b: V): V { return { x: a.x + b.x, y: a.y + b.y }; }
function `-`(this a: V): V { return { x: -a.x, y: -a.y }; }
function mkV(x: float32, y: float32): V { return { x: x, y: y }; }
function sumV(v: V): float32 { return v.x + v.y; }

function main(): void {
	const a = mkV(2.0, 3.0);
	const b = mkV(4.0, 5.0);
	const c = mkV(1.0, 1.0);

	const s1: float32 = sumV(a * b + c);     // (9,16)  → 25
	const s2: float32 = sumV(a + b + c);     // (7,9)   → 16
	const s3: float32 = sumV(c + a * b);     // (9,16)  → 25
	const s4: float32 = sumV(a * b * c + a); // (10,18) → 28
	let v = mkV(1.0, 1.0);
	v += a * b;                              // (9,16)  → 25
	const s5: float32 = sumV(v);
	const s6: float32 = sumV(-(a + b));      // (-6,-8) → -14

	const acc: int32 = (s1 + s2 + s3 + s4 + s5 + s6) as int32;  // 25+16+25+28+25-14 = 105
	console.log(`op-chain acc=${acc}`);
}

main();
