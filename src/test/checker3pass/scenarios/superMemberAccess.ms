import { checkOnly } from "../helpers";

test "super reaches the parent's methods, from an override and from another method" {
	const errors = checkOnly(`
class P { v(): int32 { return 1; } }
class Q extends P {
	v(): int32 { return super.v() + 1; }
	twice(): int32 { return super.v() * 2; }
}
`).errors;
	assert errors.length == 0, errors.join("\n");
}

test "a parent's field is not reachable through super" {
	const errors = checkOnly(`
class P { n: int32 = 1; }
class Q extends P { read(): int32 { return super.n; } }
`).errors;
	assert errors.length == 1 && errors[0] == "Class field 'n' defined by the parent class is not accessible in the child class via super", errors.join("\n");
}
