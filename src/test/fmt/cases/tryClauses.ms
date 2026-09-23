import { assertFmtLossless } from "../roundtrip";

test "fmt: try/finally gains no catch" {
	assert assertFmtLossless("function f(): void {\n\ttry {\n\t\tg();\n\t} finally {\n\t\th();\n\t}\n}\n");
}

test "fmt: try/catch gains no finally" {
	assert assertFmtLossless("function f(): void {\n\ttry {\n\t\tg();\n\t} catch (e) {\n\t\th();\n\t}\n}\n");
}

test "fmt: try/catch/finally with an empty finally keeps it" {
	assert assertFmtLossless("function f(): void {\n\ttry {\n\t\tg();\n\t} catch {\n\t\th();\n\t} finally {}\n}\n");
}
