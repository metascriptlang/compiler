// GUARD-CHECK-FAIL cannot return Span<int32>
// GUARD-CHECK-FAIL cannot return Span<uint8>
// GUARD-CHECK-FAIL cannot return Span<float64>
// GUARD-CHECK-FAIL cannot return Span<int16>
// GUARD-CHECK-FAIL 'passthrough' cannot return

function view(a: int32[]): Span<int32> { // GUARD-REFUSED
	return a;
}

class Buf {
	slice(b: uint8[]): Span<uint8> { // GUARD-REFUSED
		return b;
	}
}

const g = (a: float64[]): Span<float64> => a; // GUARD-REFUSED

let h: (a: int16[]) => Span<int16>; // GUARD-REFUSED

function passthrough(s: Span<int64>) { // GUARD-REFUSED
	return s;
}
