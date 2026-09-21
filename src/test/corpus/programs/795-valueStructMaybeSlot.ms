// @stdout: call=1.5 literal=2.5 assign=3.5 array=4.5

// A value struct reaches a nullable slot through every object-shape pre-check site:
// declaration, assignment, and array element. The slot wraps the payload instead of
// comparing the value with the generated `{ value, present }` carrier.
struct V { n: float64; }

function makeV(n: float64): V {
	const v: V = { n };
	return v;
}

export function main(): void {
	const fromCall: V | null = makeV(1.5);
	const fromLiteral: V | null = { n: 2.5 };
	let assigned: V | null = null;
	assigned = makeV(3.5);
	const values: (V | null)[] = [makeV(4.5), null];
	const arrayValue = values[0];

	if (fromCall != null && fromLiteral != null && assigned != null && arrayValue != null) {
		console.log(`call=${fromCall.n} literal=${fromLiteral.n} assign=${assigned.n} array=${arrayValue.n}`);
	}
}

main();
