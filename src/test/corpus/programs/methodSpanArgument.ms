// @stdout: function 2 0 method 3 2 0 static 1 extension 4
// note: an array passed to a Span parameter becomes a view of it at every call shape: a function, an instance method (its receiver is not an argument), a static method and an extension, and a default argument as an explicit one. On JS an instance method call kept the array, so the method read `undefined` for its length.

const NONE: uint8[] = [];

function count(xs: Readonly<Span<uint8>> = NONE): number {
	return xs.length;
}

class Reader {
	count(xs: Readonly<Span<uint8>> = NONE): number {
		return xs.length;
	}

	static total(xs: Readonly<Span<uint8>>): number {
		return xs.length;
	}
}

function extCount(this r: Reader, xs: Readonly<Span<uint8>>): number {
	return xs.length;
}

const r = new Reader();
const pair: uint8[] = [1, 2];
console.log(`function ${count(pair)} ${count()} method ${r.count([1, 2, 3])} ${r.count(pair)} ${r.count()} static ${Reader.total([1])} extension ${r.extCount([1, 2, 3, 4])}`);
