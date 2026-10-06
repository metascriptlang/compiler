import { compileToC } from "../helpers";

const PRELUDE = `
enum Two { A, B }
enum Byte { Low = 0, Top = 255 }
enum Word { Low = 0, High = 300 }
enum Signed { Below = -1, Zero = 0 }
enum Unordered { Hi = 70000, Lo = 1 }
extern enum Native { N0, N1 }
`;

function cFor(body: string): string {
	const c = compileToC(PRELUDE + body);
	if (!c.ok) return "";
	return c.value;
}

test "an enum whose ordinals fit a byte is uint8_t" {
	const c = cFor("struct P { a: Two; b: Byte; }");
	assert c != "";
	assert c.contains("typedef uint8_t Two");
	assert c.contains("typedef uint8_t Byte");
}

test "an enum whose largest ordinal fits 16 bits is uint16_t" {
	const c = cFor("struct P { w: Word; }");
	assert c != "";
	assert c.contains("typedef uint16_t Word");
}

test "a negative ordinal keeps int32_t" {
	const c = cFor("struct P { s: Signed; }");
	assert c != "";
	assert c.contains("typedef int32_t Signed");
}

test "the largest ordinal decides, not the last one" {
	const c = cFor("struct P { u: Unordered; }");
	assert c != "";
	assert c.contains("typedef int32_t Unordered");
}

test "an extern enum keeps the C type and emits no typedef" {
	const c = cFor("struct P { n: Native; }");
	assert c != "";
	assert !c.contains("typedef uint8_t Native");
	assert !c.contains("typedef int32_t Native");
}
