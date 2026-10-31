import { strictErrorCount, hasError } from "./helpers";

const REF = "function bump(ref x: int32): void { x = x + 1; }\nfunction plain(x: int32): void {}\n";

test "a function with a ref parameter does not fit a function type without it" {
	assert hasError(REF + "function visit(f: (x: int32) => void): void {}\nvisit(bump);", "Argument type mismatch in 'visit' arg 0");
}

test "a function without a ref parameter does not fit a function type with it" {
	assert hasError(REF + "function visit(f: (ref x: int32) => void): void {}\nvisit(plain);", "Argument type mismatch in 'visit' arg 0");
}

test "a function with a ref parameter does not fit an out slot" {
	assert hasError(REF + "function visit(f: (out x: int32) => void): void {}\nvisit(bump);", "Argument type mismatch in 'visit' arg 0");
}

test "a function with a ref parameter fits a function type that names ref" {
	assert strictErrorCount(REF + "function visit(f: (ref x: int32) => void): void {}\nvisit(bump);\nconst g: (ref x: int32) => void = bump;") == 0;
}
