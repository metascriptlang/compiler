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

test "super() packs separate arguments into the parent's rest parameter and still needs the fixed ones" {
	const parent = `
class H { total: int32 = 0; constructor(head: int32, ...xs: int32[]) { this.total = head; } }
`;
	const packed = checkOnly(parent + `class K extends H { constructor() { super(1, 2, 3); } }`).errors;
	assert packed.length == 0, packed.join("\n");
	const short = checkOnly(parent + `class K extends H { constructor() { super(); } }`).errors;
	assert short.length == 1 && short[0] == "super() expects at least 1 arguments, got 0", short.join("\n");
	const mistyped = checkOnly(parent + `class K extends H { constructor() { super(1, "two"); } }`).errors;
	assert mistyped.length == 1, mistyped.join("\n");
}
