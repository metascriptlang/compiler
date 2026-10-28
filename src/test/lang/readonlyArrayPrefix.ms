function first(values: readonly string[]): string {
	return values[0];
}
function optional(values: readonly (string | null)[]): string {
	return values[0] ?? "empty";
}
function maybe(values: readonly string[] | null): string {
	return values == null ? "missing" : values[0];
}
function nested(values: readonly string[][]): string {
	return values[0][0];
}

test "readonly array spelling preserves parameter and local view reads" {
	const values: string[] = ["value"];
	const view: readonly string[] = values;
	assert first(view) == "value";
	assert values[0] == "value";
}

test "readonly array spelling preserves parenthesized and nullable operands" {
	assert optional([null]) == "empty";
	assert optional(["value"]) == "value";
	assert maybe(null) == "missing";
	assert maybe(["value"]) == "value";
}

test "readonly array spelling preserves nested arrays" {
	const values: string[][] = [["nested"]];
	assert nested(values) == "nested";
}
