import { isPlainData } from "std/typetraits";

when (true) {
	const selected: int32 = 7;
} else {
	function unused(): int32 { return missingValue(); }
}

function layout<T>(): int32 {
	when (true && isPlainData<T>()) {
		return 1;
	} else {
		return 2;
	}
}

test "true when splices declarations into the enclosing scope" {
	assert selected == 7;
}

test "false when drops unchecked declarations" {
	when (false) {
		const value: int32 = missingValue();
	} else {
		const value: int32 = 3;
	}
	assert value == 3;
}

test "boolean when operators retain first-true branch selection" {
	when (!(true && false) && (true || false)) {
		const value: int32 = 11;
	} else when (true) {
		const value: int32 = missingValue();
	} else {
		const value: int32 = missingValue();
	}
	assert value == 11;
}

test "a literal mixed with a trait still selects per generic instance" {
	assert layout<int32>() == 1;
	assert layout<string>() == 2;
}
