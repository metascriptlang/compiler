import { assertFmtLossless } from "../roundtrip";

test "fmt: a call keeps its explicit type argument" {
	assert assertFmtLossless("const s = createSignal<number>(0);\n");
}

test "fmt: a method call keeps several nested type arguments" {
	assert assertFmtLossless("const m = store.get<Map<string, int32>, Named>(key);\n");
}
