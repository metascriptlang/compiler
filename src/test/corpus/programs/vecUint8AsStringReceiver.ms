// @stdout: generic field hi
// @stdout: plain field ok
// @stdout: local ok
// @stdout: array control yo

struct Decoded<T> {
	value: T;
	next: int32;
}
struct Plain {
	value: Vec<uint8>;
}

function generic(): Decoded<Vec<uint8>> {
	let bytes: Vec<uint8> = [];
	bytes.push(104);
	bytes.push(105);
	return { value: bytes, next: 2 };
}
function plain(): Plain {
	let bytes: Vec<uint8> = [];
	bytes.push(111);
	bytes.push(107);
	return { value: bytes };
}

const first = generic();
console.log("generic field " + first.value.asString());
const second = plain();
console.log("plain field " + second.value.asString());
const local = second.value;
console.log("local " + local.asString());
const control: uint8[] = [121, 111];
console.log("array control " + control.asString());
