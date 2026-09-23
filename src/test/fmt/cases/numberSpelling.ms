import { assertFmtLossless } from "../roundtrip";

test "fmt: a float literal keeps its fraction" {
	assert assertFmtLossless("const a: float64 = 1.0;\nconst b = 200.0 * 0.5;\n");
}

test "fmt: hex, binary and separated literals keep their spelling" {
	assert assertFmtLossless("const m = 0xff;\nconst b = 0b1010;\nconst big = 1_000_000;\n");
}

test "fmt: an exponent literal and a method on a float keep their spelling" {
	assert assertFmtLossless("const e = 1.5e-3;\nconst s = 2.50.toFixed(1);\n");
}
