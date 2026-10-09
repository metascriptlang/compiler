// @stdout: g8=uint64 g32=uint64 h8=uint64 gNeg=int64 pair=unsigned u8=200 u32=7 wide=200 neg=-3
// note: an unsigned value passed to overloads of a wider signed and a wider unsigned integer, or stored into a union of both, takes the unsigned one; a signed value still takes the signed one, and with two arguments the candidate whose every argument keeps its signedness wins. Same output on C, JS and the Raiser.
function g(v: int64): string { return "int64"; }
function g(v: uint64): string { return "uint64"; }
function h(v: int32): string { return "int32"; }
function h(v: uint64): string { return "uint64"; }
function pair(a: int64, b: uint64): string { return "signed"; }
function pair(a: uint64, b: uint64): string { return "unsigned"; }

const small: uint8 = 200;
const mid: uint32 = 7;
const neg: int8 = -3;
const u8: int64 | uint64 = small;
const u32: int64 | uint64 | float64 = mid;
const wide: int32 | uint64 = small;
const signed: int64 | uint64 = neg;
console.log([
	`g8=${g(small)}`,
	`g32=${g(mid)}`,
	`h8=${h(small)}`,
	`gNeg=${g(neg)}`,
	`pair=${pair(small, mid)}`,
	`u8=${String(u8 as uint64)}`,
	`u32=${String(u32 as uint64)}`,
	`wide=${String(wide as uint64)}`,
	`neg=${String(signed as int64)}`,
].join(" "));
