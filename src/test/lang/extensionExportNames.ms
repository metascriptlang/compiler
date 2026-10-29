import { EntryHandle as ImportedHandle } from "./fixtures/entryHandle";

export function then(
	this handle: ImportedHandle,
	onFulfilled: (value: int32) => void,
): void {
	onFulfilled(handle.value);
}

export function label(this handle: ImportedHandle): string {
	return "value" + handle.value.toString();
}

export function increment(value: int32): int32 {
	return value + 1;
}

test "an exported receiver then keeps its thenable adaptation" {
	const first = new ImportedHandle(7);
	const second = new ImportedHandle(9);
	assert await first == 7;
	assert await second == 9;
}

test "an exported receiver routine keeps its imported receiver identity" {
	const handle = new ImportedHandle(11);
	assert handle.label() == "value11";
}

test "an ordinary free export remains callable" {
	assert increment(4) == 5;
}
