import { isPlainData } from "std/typetraits";

when (true) {
	const selected: int32 = 7;
} else {
	function unused(): int32 { return missingValue(); }
}

function branch(): int32 {
	when (false) {
		return missingValue();
	} else when (!(true && false) && (true || false)) {
		const value: int32 = 3;
	}
	return value + selected;
}

function layout<T>(): int32 {
	when (true && isPlainData<T>()) {
		return 1;
	} else {
		return 2;
	}
}

const result = `${selected} ${branch()} ${layout<int32>()} ${layout<string>()}`;
if (result != "7 10 1 2") {
	throw new Error("boolean when changed branch splicing or trait deferral");
}
console.log(result);
