// GUARD-JS
// GUARD-CHECK-FAIL cannot write through
// GUARD-CHECK-FAIL 'push' mutates its receiver
// GUARD-CHECK-FAIL 'readonly' applies only to an array type

function writeIndex(values: readonly string[]): void {
	values[0] = "changed"; // GUARD-REFUSED
}
function append(values: readonly string[]): void {
	values.push("changed"); // GUARD-REFUSED
}
function appendNested(values: readonly string[][]): void {
	values[0].push("changed"); // GUARD-REFUSED
}
function notAnArray(value: readonly string): void {} // GUARD-REFUSED
