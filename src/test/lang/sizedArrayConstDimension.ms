// A sized array whose dimension is a named const read size 0
//
// Symptom:    `let a: int32[COUNT] = []` with COUNT a module const emitted
//             msSizedArray_int32_t_0 on C (clang: "initializer for aggregate
//             with no elements requires explicit braces") and a zero-length
//             array on JS (`length 0 undefined`); after 0e66359b the
//             constant-index check reported `int32[0] (0..-1)` instead.
// Root cause: resolveAnnotation parsed the T[N] dimension with parseIntStr,
//             which returns 0 for any name; the constant evaluator was never
//             asked.
// Fix:        a non-digit dimension resolves through constantLiteralOf on the
//             named binding (constArrayDimension, checker/resolvePass.ms); a
//             name that does not fold to a non-negative integer is an error at
//             the declaration.

import { COUNT } from "./sizedArrayConstDimensionHelper";
import { hasError, strictErrorCount } from "../handoff/helpers";
import { compileProjectToJSWithStd, MapEntry } from "../helpers";

const SAME: int32 = 4;
const SIX: int32 = 6;
const CHAINED: int32 = SIX;

function sum613(values: Span<int32>): int32 {
	let total = 0;
	for (let i = 0; i < values.length; i += 1) { total += values[i]; }
	return total;
}

test "a same-module const dimension gives the array its size" {
	let a: int32[SAME] = [];
	a[3] = 7;
	assert a.length == 4;
	assert a[3] == 7;
	assert sum613(a) == 7;
}

test "an imported const dimension gives the array its size" {
	let a: int32[COUNT] = [];
	a[3] = 7;
	assert a.length == 4;
	assert a[3] == 7;
	assert sum613(a) == 7;
}

test "a const chained through another const folds" {
	let a: int32[CHAINED] = [];
	a[5] = 1;
	assert a.length == 6;
	assert sum613(a) == 1;
}

test "a literal dimension still resolves" {
	assert strictErrorCount("const K: int32 = 2;\nfunction f(): int32 { let a: int32[4] = []; return a[K]; }") == 0;
}

test "a let dimension is an error at the declaration" {
	assert hasError("function f(): int32 { let n = 4; let a: int32[n] = []; return a[0]; }", "array size 'n' must be a compile-time integer constant");
}

test "a float const dimension is an error" {
	assert hasError("const F: float64 = 4.0;\nfunction f(): int32 { let a: int32[F] = []; return a[0]; }", "array size 'F' must be a compile-time integer constant");
}

test "an unknown dimension is an error" {
	assert hasError("function f(): int32 { let a: int32[MISSING613] = []; return a[0]; }", "array size 'MISSING613' must be a compile-time integer constant");
}

test "JS emits the folded size for a const dimension" {
	const entries: MapEntry[] = [
		{ entryPath: "test/sizedConsthelperjs.ms", entrySource: "export const COUNT: int32 = 4;\n" },
		{
			entryPath: "test/sizedConstmainjs.ms",
			entrySource: "import { COUNT } from \"./sizedConsthelperjs\";\nfunction main(): int32 { let a: int32[COUNT] = []; a[3] = 7; console.log(`length ${a.length} ${a[3]}`); return 0; }\nprocess.exit(main());\n",
		},
	];
	const js = compileProjectToJSWithStd(entries, "test/sizedConstmainjs.ms");
	assert js.contains("Int32Array(4)"), js;
	assert !js.contains("Int32Array(0)"), js;
}
