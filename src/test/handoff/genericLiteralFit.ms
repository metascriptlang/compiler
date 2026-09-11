// Route 15d: Checker — an object literal argument to a generic call is constructed against the instantiated formal

import { strictErrorCount, hasError } from "./helpers";

const FOR_OPT = "function For<T>(props: { each: () => T[]; children: (item: T) => string; fallback?: string | null }): string { return props.children(props.each()[0]); }\nconst xs: number[] = [7, 8];\n";
const FOR_REQ = "function For<T>(props: { each: () => T[]; children: (item: T) => string }): string { return props.children(props.each()[0]); }\n";
const CC = "function createComponent<P>(Comp: (props: P) => string, props: P): string { return Comp(props); }\n";
const LIT = "{ each: () => xs, children: (item: number) => \"item \" + item.toString() }";

// ===== Accepted: an omitted optional field is default-initialized, generic or not =====

test "a generic call accepts a literal that omits an optional field" {
	assert strictErrorCount(FOR_OPT + "const s = For(" + LIT + ");") == 0;
}

test "a generic function passed as a value accepts the same literal" {
	assert strictErrorCount(FOR_OPT + CC + "const s = createComponent(For, " + LIT + ");") == 0;
}

test "supplying the optional field keeps working" {
	assert strictErrorCount(FOR_OPT + "const s = For({ each: () => xs, children: (item: number) => \"i\", fallback: null });") == 0;
}

test "the non-generic twin accepts the omitted field" {
	const src = "function For(props: { each: () => number[]; children: (item: number) => string; fallback?: string | null }): string { return props.children(props.each()[0]); }\nconst xs: number[] = [7, 8];\nconst s = For(" + LIT + ");";
	assert strictErrorCount(src) == 0;
}

// ===== Rejected: the literal must still construct the instantiated formal =====

test "a missing function-typed field is reported by name" {
	assert hasError(FOR_REQ + "const xs: number[] = [7, 8];\nconst s = For({ each: () => xs });", "field 'children' must be initialized");
}

test "two fields binding T to different types inside one literal are rejected" {
	assert hasError(FOR_REQ + "const s = For({ each: () => [7, 8], children: (item: number) => \"i\" });", "'T' is bound to both int32 and number");
}

test "the within-literal conflict is reported once" {
	assert strictErrorCount(FOR_REQ + "const s = For({ each: () => [7, 8], children: (item: number) => \"i\" });") == 1;
}

test "a generic function passed as a value reports the same conflict" {
	const src = FOR_REQ + CC + "const s = createComponent(For, { each: () => [7, 8], children: (item: number) => \"i\" });";
	assert hasError(src, "'T' is bound to both int32 and number");
	assert strictErrorCount(src) == 1;
}
