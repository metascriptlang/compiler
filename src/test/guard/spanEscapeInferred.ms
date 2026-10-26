// GUARD-CHECK-FAIL field 's' of 'object literal' cannot hold Span<uint8>
// GUARD-CHECK-FAIL the return value of 'inArray' of type Span<uint8>[] cannot hold Span<uint8> inside it
// GUARD-CHECK-FAIL the return value of 'inTuple' of type [number, Span<uint8>] cannot hold Span<uint8> inside it

function inLiteral() {
	const a: uint8[] = [1, 2, 3, 4, 5];
	const v = a[1...3];
	return { s: v }; // GUARD-REFUSED
}

function inNested() {
	const a: uint8[] = [1, 2, 3, 4, 5];
	const v = a[1...3];
	return { w: { s: v } }; // GUARD-REFUSED
}

function inArray() { // GUARD-REFUSED
	const a: uint8[] = [1, 2, 3, 4, 5];
	const v = a[1...3];
	return [v];
}

function inTuple() { // GUARD-REFUSED
	const a: uint8[] = [1, 2, 3, 4, 5];
	const v = a[1...3];
	return [1, v] as [number, Span<uint8>];
}
