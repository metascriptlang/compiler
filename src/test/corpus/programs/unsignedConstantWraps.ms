// @stdout: uint8 255 0 5 0 | uint16 65535 0 5 0 | uint32 4294967295 0 5 0 | uint64 18446744073709551615 9223372036854775809 18446744073709551615
function id(v: int64): int64 { return v; }

function width8(): string {
	const k = `${-1 as uint8} ${256 as uint8} ${1099511627781 as uint8} ${(200 + 56) as uint8}`;
	const r = `${id(-1) as uint8} ${id(256) as uint8} ${id(1099511627781) as uint8} ${id(200 + 56) as uint8}`;
	return k == r ? k : k + " but at run time " + r;
}

function width16(): string {
	const k = `${-1 as uint16} ${65536 as uint16} ${1099511627781 as uint16} ${(65000 + 536) as uint16}`;
	const r = `${id(-1) as uint16} ${id(65536) as uint16} ${id(1099511627781) as uint16} ${id(65000 + 536) as uint16}`;
	return k == r ? k : k + " but at run time " + r;
}

function width32(): string {
	const k = `${-1 as uint32} ${4294967296 as uint32} ${1099511627781 as uint32} ${(4294967000 + 296) as uint32}`;
	const r = `${id(-1) as uint32} ${id(4294967296) as uint32} ${id(1099511627781) as uint32} ${id(4294967000 + 296) as uint32}`;
	return k == r ? k : k + " but at run time " + r;
}

function width64(): string {
	const k = `${-1 as uint64} ${-9223372036854775807 as uint64} ${18446744073709551615 as uint64}`;
	const r = `${id(-1) as uint64} ${id(-9223372036854775807) as uint64} ${id(-1) as uint64}`;
	return k == r ? k : k + " but at run time " + r;
}

console.log(`uint8 ${width8()} | uint16 ${width16()} | uint32 ${width32()} | uint64 ${width64()}`);
