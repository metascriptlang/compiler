// @stdout: 3 true true 97 true
// note: a view read as an argument of Result.ok is not a change of the string the view borrows from, because Result.ok is a body-less generic whose formal stands for the scalar the call passes; a call passing a value that can hold a pointer keeps changing what the borrow reaches.

function count(text: string): int32 {
	const bytes = text.asBytes();
	return bytes.length as int32;
}
function count2(text: string): Result<int64, int32> {
	const bytes = text.asBytes();
	return Result.ok(bytes.length);
}
function first(text: string): Result<uint8, int32> {
	const bytes = text.asBytes();
	return Result.ok(bytes[0]);
}
function nested(text: string): Result<int64, int32> {
	const bytes = text.asBytes();
	const n: int64 = bytes.length > 0 ? bytes.length : 0;
	return Result.ok(n + bytes.length);
}
function value(r: Result<uint8, int32>): int32 {
	return r.ok ? r.value as int32 : -1;
}

console.log(`${count("abc")} ${count2("ab").ok} ${first("ab").ok} ${value(first("a"))} ${nested("xy").ok}`);
