// Phase 5 — two-pass overload resolution with context-sensitive args.
//
// Shows: specific overloads picked via EnumLiteral discrimination on arg[0],
// object literal arg[1] checked against the winner's struct variant in Pass 2.
// Runtime dispatch on a wide `Kind` param falls through to the impl overload.

enum Kind { Circle, Square, Line }

type CircleData = { radius: number };
type SquareData = { side: number };
type LineData = { length: number };

function area(k: Kind.Circle, d: CircleData): number;
function area(k: Kind.Square, d: SquareData): number;
function area(k: Kind.Line, d: LineData): number;
function area(k: Kind, d: CircleData | SquareData | LineData): number {
	return match (k) {
		Kind.Circle => (d as CircleData).radius * (d as CircleData).radius * 3,
		Kind.Square => (d as SquareData).side * (d as SquareData).side,
		Kind.Line => 0,
	};
}

function main(): int32 {
	// Specific overload — arg[0] is EnumLiteral(Kind, Circle), arg[1] is a
	// partial object literal typed via the CircleData variant in Pass 2.
	const c = area(Kind.Circle, { radius: 4 });
	console.log(c);

	// Specific overload — Square variant.
	const s = area(Kind.Square, { side: 5 });
	console.log(s);

	// Specific overload — Line variant (degenerate, returns 0).
	const l = area(Kind.Line, { length: 10 });
	console.log(l);

	// Runtime kind falls through to the wide impl.
	let runtime: Kind = Kind.Square;
	const runtimeData: CircleData | SquareData | LineData = { side: 7 };
	const r = area(runtime, runtimeData);
	console.log(r);

	return 0;
}

main();
