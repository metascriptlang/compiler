// @stdout: 3 2 1
// @exit: 0

type Bytes = uint8[] & { __brand: "Bytes" };

function bytes(n: int32): Bytes {
	return new Array<uint8>(n) as Bytes;
}

function size<D extends string | uint8[]>(d: D): int64 {
	return typeof d == "string" ? d.asBytes().length : d.length;
}

function spelled(n: int32): uint8[] & { __brand: "Bytes" } {
	return bytes(n);
}

async function later(n: int32): Promise<uint8[] & { __brand: "Bytes" }> {
	return bytes(n);
}

const named: Bytes = bytes(3);
console.log(size(named), size(spelled(2)), size(await later(1)));
