import { hasError, strictErrorCount } from "./helpers";

const ENUMS = "enum Kind { A, B, C }\nenum Holes { P = 1, Q = 5, R = 9 }\n";

test "a constant outside an enum's ordinals is refused at the conversion" {
	assert hasError(ENUMS + "const k = 300 as Kind;", "cannot convert 300 to Kind");
	assert hasError(ENUMS + "const k = (-1) as Kind;", "cannot convert -1 to Kind");
	assert hasError(ENUMS + "const N = 3;\nconst k = N as Kind;", "cannot convert 3 to Kind");
	assert hasError(ENUMS + "const h = 10 as Holes;", "cannot convert 10 to Holes");
}

test "a constant inside an enum's ordinals converts, a hole included" {
	assert strictErrorCount(ENUMS + "const k = 2 as Kind;") == 0;
	assert strictErrorCount(ENUMS + "const h = 3 as Holes;") == 0;
}
