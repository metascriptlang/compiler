// @stdout: int 7
// @stdout: uint 7
// @stdout: fraction 6
// @stdout: wide 4000000005
// @stdout: implicit 7
// @stdout: plain 7
// @stdout: member 7
// note: a union of number literals is stored as its base number, so `as int64` and `as uint64` convert it the way they convert that base; only a union with a non-literal member is read through its tag.
function toInt(u: 1 | 2): int64 {
	return u as int64;
}

function toUint(u: 1 | 2): uint64 {
	return u as uint64;
}

function fromFraction(u: 0.5 | 1.5): int64 {
	return u as int64;
}

function fromWide(u: 3000000000 | 4000000000): int64 {
	return u as int64;
}

function implicit(u: 1 | 2): int64 {
	const x: int64 = u;
	return x;
}

function plain(i: int32): int64 {
	return i as int64;
}

function member(v: int32 | string): int64 {
	return v as int64;
}

const big: int64 = 5;
console.log("int " + (toInt(2) + big).toString());
console.log("uint " + (toUint(2) + (big as uint64)).toString());
console.log("fraction " + (fromFraction(1.5) + big).toString());
console.log("wide " + (fromWide(4000000000) + big).toString());
console.log("implicit " + (implicit(2) + big).toString());
console.log("plain " + (plain(2) + big).toString());
console.log("member " + (member(2) + big).toString());
