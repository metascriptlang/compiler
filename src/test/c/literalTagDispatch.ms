// A compare or a switch over a union's literal discriminant compares its tag on C.

import { compileToC } from "../helpers";

const SHAPES = "type Circle = { kind: \"circle\"; r: float64 };\ntype Rect = { kind: \"rect\"; w: float64; h: float64 };\ntype Shape = Circle | Rect;\n";
const NUMBERS = "type Zero = { kind: 0; r: float64 };\ntype One = { kind: 1; w: float64 };\ntype N = Zero | One;\n";

test "a string discriminant compared to a literal compares the tag" {
	const result = compileToC(SHAPES + "function area(s: Shape): float64 { if (s.kind === \"rect\") return s.w * s.h; return s.r; }\nconsole.log(area({ kind: \"circle\", r: 2 }));");
	assert result.ok, result.error;
	assert result.value.contains("_tag == 0)") && !result.value.contains("eqeq___"), result.value;
}

test "a switch over a string discriminant switches over the tag" {
	const result = compileToC(SHAPES + "function area(s: Shape): float64 { switch (s.kind) { case \"circle\": return s.r; case \"rect\": return s.w * s.h; } }\nconsole.log(area({ kind: \"circle\", r: 2 }));");
	assert result.ok, result.error;
	assert result.value.contains("switch (") && result.value.contains("_tag)") && !result.value.contains("eqeq___"), result.value;
}

test "a number discriminant compared on either side compares the tag" {
	const result = compileToC(NUMBERS + "function f(n: N): float64 { if (1 == n.kind) return n.w; return n.r; }\nconsole.log(f({ kind: 0, r: 2 }));");
	assert result.ok, result.error;
	assert result.value.contains("_tag == 1)"), result.value;
}
