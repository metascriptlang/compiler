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

test "two fields binding T to int32 and number inside one literal settle on number" {
	assert strictErrorCount(FOR_REQ + "const s = For({ each: () => [7, 8], children: (item: number) => \"i\" });") == 0;
}

test "an existing int32 array is not read as the number array T settled on" {
	const src = FOR_REQ + "const ints: int32[] = [7, 8];\nconst s = For({ each: () => ints, children: (item: number) => \"i\" });";
	assert hasError(src, "Type 'int32[]' is not assignable to type 'number[]'");
	assert strictErrorCount(src) == 1;
}

test "a generic function passed as a value settles T the same way" {
	assert strictErrorCount(FOR_REQ + CC + "const s = createComponent(For, { each: () => [7, 8], children: (item: number) => \"i\" });") == 0;
	const src = FOR_REQ + CC + "const ints: int32[] = [7, 8];\nconst s = createComponent(For, { each: () => ints, children: (item: number) => \"i\" });";
	assert hasError(src, "Type 'int32[]' is not assignable to type 'number[]'");
	assert strictErrorCount(src) == 1;
}

const ACC = "type Accessor<T> = distinct (() => T);\nfunction accessor<T>(f: () => T): Accessor<T> { return f as Accessor<T>; }\ninterface Style { height?: number | null; width?: number | null; }\n";
const BOXED = "function Boxed<T>(props: { each: () => T[]; children: (item: T) => string; style?: Accessor<Style> | null; ahead?: Accessor<number> | null }): string { return props.children(props.each()[0]); }\nconst xs: number[] = [7, 8];\n";
const MEASURE = "function measure<T>(o: { item: T; frame: Style; style: Accessor<Style>; inner: { item: T; ahead: Accessor<number> } }): string { return \"m\"; }\n";

test "an object literal property takes its struct field's type" {
	assert strictErrorCount(ACC + MEASURE + "const s = measure({ item: 1, frame: { height: 7 }, style: accessor(() => ({ height: 40 })), inner: { item: 2, ahead: accessor(() => 2) } });") == 0;
}

test "a generic call property binds its own type parameter from the field" {
	assert strictErrorCount(ACC + BOXED + "const s = Boxed({ each: () => xs, children: (item: number) => \"i\", style: accessor(() => ({ height: 40 })), ahead: accessor(() => 2) });") == 0;
}

test "a generic function passed as a value types the property the same way" {
	assert strictErrorCount(ACC + BOXED + CC + "const s = createComponent(Boxed, { each: accessor(() => xs), children: (item: number) => \"i\", style: accessor(() => ({ height: 40 })), ahead: accessor(() => 2) });") == 0;
}

test "a property the field refuses is still reported against the field" {
	const src = ACC + BOXED + CC + "const s = createComponent(Boxed, { each: accessor(() => xs), children: (item: number) => \"i\", ahead: accessor(() => \"far\") });";
	assert hasError(src, "Type 'string' is not assignable to type 'number'");
	assert strictErrorCount(src) == 1;
}
