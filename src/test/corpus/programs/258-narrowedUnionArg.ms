// Parity program — the OTHER direction of 253: a reference whose STORAGE is
// the union, narrowed to one variant by a discriminant guard, then handed back
// to a formal that wants the union. The declared type never changed, so the
// only correct conversion is identity; treating the flow-narrowed type as the
// source type made the fit path rebuild the union from a variant and emit a
// dereference of a non-pointer ("indirection requires pointer operand" — the
// program did not compile at all). Covered here at every position the narrowed
// reference can be reused: plain arg, arg used twice in one expression, arg in
// a loop over churned heap payloads, and re-widened into a fresh union local.
//
// 253 pins variant->union (a real conversion); this pins union->union through
// a narrowing (no conversion). Both are needed: 253 stayed green throughout.

interface Circle { kind: "circle"; label: string; r: float64; }
interface Square { kind: "square"; label: string; w: float64; }
type Shape = Circle | Square;

function mkCircle(i: int32): Circle {
	return { kind: "circle", label: "c-" + i.toString(), r: 2.0 };
}

function mkSquare(i: int32): Square {
	return { kind: "square", label: "s-" + i.toString(), w: 3.0 };
}

function area(s: Shape): float64 {
	return match (s.kind) {
		"circle" => s.r * s.r,
		"square" => s.w * s.w,
	};
}

function label(s: Shape): string {
	return match (s.kind) {
		"circle" => s.label,
		"square" => s.label,
	};
}

function pick(i: int32): Shape {
	if (i % 2 == 0) {
		const c: Circle = mkCircle(i);
		return c;
	}
	const q: Square = mkSquare(i);
	return q;
}

function main(): void {
	// Narrowed reference back into a union formal, in a churning loop.
	let total = 0.0;
	for (let i = 0; i < 50000; i += 1) {
		const s = pick(i);
		if (s.kind == "circle") {
			total += area(s);
		} else {
			total += area(s);
		}
	}
	console.log("total=" + total.toString());

	// Same reference consumed twice inside one expression, still narrowed.
	const one = pick(0);
	if (one.kind == "circle") {
		console.log("twice=" + label(one) + "/" + area(one).toString());
	}

	// Narrowed reference re-widened into a fresh union local.
	const two = pick(1);
	if (two.kind == "square") {
		const again: Shape = two;
		console.log("alias=" + label(again));
	}

	// Narrowed reference through a generic (Result) and back out as the union.
	const three = pick(2);
	if (three.kind == "circle") {
		const wrapped: Result<Shape, string> = Result.ok(three);
		if (wrapped.ok) {
			console.log("wrapped=" + label(wrapped.value));
		}
	}

	// Negative guard: narrowing in the ELSE branch is the same shape.
	const four = pick(3);
	if (four.kind == "circle") {
		console.log("unreached=" + label(four));
	} else {
		console.log("else=" + label(four) + "/" + area(four).toString());
	}
}

main();
