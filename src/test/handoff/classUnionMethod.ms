// Test: a method call on a union of classes — what the checker accepts and refuses

import { strictErrorCount, hasError } from "./helpers";

const UNRELATED = "class X { name(): string { return \"x\"; } size(n: int32): int32 { return n; } }\nclass Y { name(): string { return \"y\"; } size(n: string): int32 { return 0; } }\nclass Z { other(): void {} }\n";

test "a method every class of a union declares is a method of the union" {
	assert strictErrorCount(UNRELATED + "function f(v: X | Y): string { return v.name(); }") == 0;
}

test "a method one member lacks names that member" {
	assert hasError(UNRELATED + "function f(v: X | Z): string { return v.name(); }", "'Z' has no method 'name'");
}

test "members taking different parameters leave the union no single signature" {
	assert hasError(UNRELATED + "function f(v: X | Y): int32 { return v.size(1); }", "takes different parameters in 'X' and 'Y'");
}
