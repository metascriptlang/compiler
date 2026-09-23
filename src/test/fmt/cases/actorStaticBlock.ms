import { assertFmtLossless } from "../roundtrip";

test "fmt: a static block in an actor keeps static" {
	assert assertFmtLossless("actor Act {\n\tstatic k: int32 = 2;\n\tstatic {\n\t\tAct.k = Act.k * 2;\n\t}\n}\n");
}

test "fmt: a static block in a class keeps static" {
	assert assertFmtLossless("class C {\n\tstatic n: int32 = 0;\n\tstatic {\n\t\tC.n = 1;\n\t}\n}\n");
}
