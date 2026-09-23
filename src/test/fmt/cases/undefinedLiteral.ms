import { assertFmtLossless } from "../roundtrip";

test "fmt: undefined stays undefined" {
	assert assertFmtLossless("const s = new Signal<T>(undefined as T);\n");
}

test "fmt: null and undefined side by side keep their spelling" {
	assert assertFmtLossless("const a = f(null, undefined);\n");
}
