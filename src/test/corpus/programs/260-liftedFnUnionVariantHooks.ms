// Parity program — a closure over a DU whose variants carry a managed field
// (string). Lambda lifting prepends the lifted function ahead of every
// declaration, so the union is emitted BEFORE the variant interfaces; the
// variant hook prototypes (name-derived) and definitions (cache-derived)
// then disagreed and the program did not compile at all ("conflicting types
// for 'Circle__Copy'"). The plain function forced first is the explicit
// spelling of the same order. Churned string payloads keep the SAN ledger
// honest on the variant hooks.

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
	if (i % 2 == 0) {
		const c: Circle = mkCircle(i);
		return c;
	}
	const q: Square = mkSquare(i);
	return q;
}

function main(): void {
	// Closure over the union — lambda-lifted ahead of the interfaces.
	const area = (x: Shape): float64 => {
		return match (x.kind) {
			"circle" => x.r * x.r,
			"square" => x.w * x.w,
		};
	};
	let total = 0.0;
	for (let i = 0; i < 50000; i += 1) {
		total += area(pick(i));
	}
	console.log("total=" + total.toString());

	const one = pick(0);
	if (one.kind == "circle") {
		console.log("read=" + one.label + "/" + area(one).toString());
	}
}
main();
