import { assertFmtContains } from "../roundtrip";

test "fmt: a switch without cases prints empty braces" {
	assert assertFmtContains("switch (y) {}\n", "switch (y) {}\n");
}

test "fmt: an empty switch one level deeper keeps empty braces" {
	assert assertFmtContains("function f() {\n\tswitch (y) {}\n}\n", "switch (y) {}");
}
