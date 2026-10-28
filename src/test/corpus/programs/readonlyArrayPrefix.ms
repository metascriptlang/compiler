function first(values: readonly string[]): string {
	return values[0];
}
function optional(values: readonly (string | null)[]): string {
	return values[0] ?? "empty";
}
function nested(values: readonly string[][]): string {
	return values[0][0];
}
function maybe(values: readonly string[] | null): string {
	return values == null ? "missing" : values[0];
}
const rows: string[][] = [["nested"]];
const result = `${first(["value"])} ${optional([null])} ${nested(rows)} ${maybe(null)}`;
console.log(result);
if (result != "value empty nested missing") throw new Error("readonly array spelling changed a value");
