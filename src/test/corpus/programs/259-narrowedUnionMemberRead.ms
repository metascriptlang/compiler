// Parity program — the read-side sibling of 258: a local whose STORAGE is
// the union, narrowed by a discriminant guard, then read FIELD-BY-FIELD.
// 258 pins passing the narrowed reference back to a union formal; this pins
// member reads on it. Both were unreachable before their fixes: the C build
// of either shape failed at clang ("member reference type ... is not a
// pointer" / "indirection requires pointer operand"), so no corpus program
// could carry the shape. Heap-string payloads churned in a loop keep the SAN
// ledger honest on the variant slots.

interface Circle { kind: "circle"; label: string; r: float64; }
interface Square { kind: "square"; label: string; w: float64; }
type Shape = Circle | Square;

function mkCircle(i: int32): Circle {
	return { kind: "circle", label: "c-" + i.toString(), r: 2.0 };
}

function mkSquare(i: int32): Square {
	return { kind: "square", label: "s-" + i.toString(), w: 3.0 };
}

function pick(i: int32): Shape {
	if (i % 2 === 0) {
		const c: Circle = mkCircle(i);
		return c;
	}
	const q: Square = mkSquare(i);
	return q;
}

function main(): void {
	// Field reads on a narrowed LOCAL, in a churning loop.
	let total = 0.0;
	for (let i = 0; i < 50000; i += 1) {
		const s = pick(i);
		if (s.kind === "circle") {
			total += s.r;
		} else {
			total += s.w;
		}
	}
	console.log("total=" + total.toString());

	// Several reads off the same narrowed local, string payload included.
	const one = pick(0);
	if (one.kind === "circle") {
		console.log("read=" + one.label + "/" + one.r.toString());
	}

	// Else-branch narrowing is the same shape.
	const two = pick(1);
	if (two.kind === "circle") {
		console.log("unreached=" + two.label);
	} else {
		console.log("else=" + two.label + "/" + two.w.toString());
	}
}

main();
