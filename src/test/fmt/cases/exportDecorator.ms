import { assertFmtLossless } from "../roundtrip";

test "fmt: export before a decorator stays first" {
	assert assertFmtLossless("export @withExtra class Exported {\n\tn: int32 = 0;\n}\n");
}

test "fmt: export before a qualified decorator with arguments stays first" {
	assert assertFmtLossless("export @lib.touch(1) class ExportedFirst {}\n");
}

test "fmt: a decorator before export stays first" {
	assert assertFmtLossless("@withExtra\nexport class Exported {}\n");
}
