// A local T[N] initialized with [] started empty on JS
//
// Symptom:    `let fixed: int32[4] = []; fixed[3] = 7;` printed
//             `index undefined length 0 forOf 0` on JS; C printed
//             `index 7 length 4 forOf 7`.
// Root cause: js emitArrayLiteral emitted only the written elements
//             (`new Int32Array([])` has length 0), while C zero-fills all N
//             slots of the compound literal.
// Fix:        a SizedArray-typed literal carries all N entries — jsDefaultValue
//             for the empty literal, elements then zero-fill to N otherwise
//             (codegen/js/expressions.ms).

import { compileProjectToJSWithStd, MapEntry } from "../helpers";

function sum614(values: Span<int32>): int32 {
	let total = 0;
	for (let i = 0; i < values.length; i += 1) { total += values[i]; }
	return total;
}

test "an empty literal still gives N slots" {
	let fixed: int32[4] = [];
	fixed[3] = 7;
	let viaOf = 0;
	for (const value of fixed) { viaOf += value; }
	assert fixed[3] == 7;
	assert fixed.length == 4;
	assert viaOf == 7;
}

test "a partial literal zero-fills the tail" {
	let fixed: int32[4] = [7];
	assert fixed.length == 4;
	assert fixed[0] == 7;
	assert fixed[1] == 0;
	assert fixed[3] == 0;
}

test "a value-struct element array carries N slots" {
	let pts: Bug614Point[2] = [];
	assert pts.length == 2;
	pts[1] = { x: 3, y: 4 };
	assert pts[1].y == 4;
}

test "the local passes as Span<T>" {
	let fixed: int32[4] = [];
	fixed[2] = 9;
	assert sum614(fixed) == 9;
}

test "JS emits the fixed size for the literal" {
	const entries: MapEntry[] = [
		{
			entryPath: "test/sizedLiteraljs.ms",
			entrySource: "struct Bug614JPoint { x: int32; y: int32; }\nfunction main(): int32 { let sized614: int32[4] = []; sized614[3] = 7; let pts614: Bug614JPoint[2] = []; return sized614[3] + pts614.length; }\nprocess.exit(main());\n",
		},
	];
	const js = compileProjectToJSWithStd(entries, "test/sizedLiteraljs.ms");
	assert js.contains("sized614 = new Int32Array(4);"), js;
	assert js.contains("pts614 = Array.from({ length: 2 }, () => ({ x: 0, y: 0 }));"), js;
}

struct Bug614Point { x: int32; y: int32; }
