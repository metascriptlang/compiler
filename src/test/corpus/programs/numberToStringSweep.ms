// Number, int64 and uint64 to text over a deterministic sweep. Parity programs byte-compare C,
// the Raiser and JS-on-node, so a digest that matches the host's formatting proves the C
// formatter prints what the host prints for every swept value.

const modulus = 1000000007.0;
let digest = 0.0;
let count = 0;

function mix(text: string): void {
	for (let i = 0; i < text.length; i++) {
		digest = (digest * 31.0 + (text.charCodeAt(i) as float64)) % modulus;
	}
	digest = (digest * 31.0 + 10.0) % modulus;
	count += 1;
}

function mixNumber(value: float64): void {
	mix(`${value}`);
	mix(value.toString());
}

function section(name: string): void {
	console.log(`${name} count=${count} digest=${digest}`);
	digest = 0.0;
	count = 0;
}

let state = 20241026.0;
function next(): float64 {
	state = (state * 48271.0) % 2147483647.0;
	return state;
}

const specials: float64[] = [
	0.0, -0.0, NaN, Infinity, -Infinity, 5e-324, -5e-324, 2.2250738585072009e-308, 2.2250738585072014e-308,
	1.7976931348623157e308, -1.7976931348623157e308, 1.0, -1.0, 0.1, 0.2, 0.3, 0.1 + 0.2, 1.0 / 3.0, 2.0 / 3.0,
	1e21, 1e-7, 1e-6, 1.5e-6, 999999999999999.9, 1e15, 1e16, 123456789012345680000.0, 1e21 - 1e5,
	9007199254740991.0, 9007199254740992.0, 9007199254740993.0, -9007199254740991.0, 4294967296.0, 2147483648.0,
	0.000001, 0.0000001, 123456.789, 100.0, 1000000.0, 4.35, 4.349999999999999, 0.5, 1.5, 2.5, 5e-5, 8.41e21,
	2.718281828459045, 3.141592653589793, 1.7976931348623157e308 / 3.0,
];
for (const value of specials) mixNumber(value);
section("specials");

const powersOfTwo: float64[] = [];
const inversePowersOfTwo: float64[] = [];
let power = 1.0;
let inverse = 1.0;
for (let e = 0; e <= 1023; e++) {
	powersOfTwo.push(power);
	inversePowersOfTwo.push(inverse);
	power *= 2.0;
	inverse *= 0.5;
}
const increment = 1.0 + 2.220446049250313e-16;
const decrement = 1.0 - 1.1102230246251565e-16;
for (let i = 0; i < powersOfTwo.length; i++) {
	const x = powersOfTwo[i];
	mixNumber(x);
	mixNumber(-x);
	mixNumber(x * increment);
	mixNumber(x * decrement);
	mixNumber(1.0 / x);
	mixNumber((1.0 / x) * increment);
	mixNumber((1.0 / x) * decrement);
}
section("powers of two");

for (let k = -323; k <= 308; k++) {
	const x = Number("1e" + k);
	mixNumber(x);
	mixNumber(x * increment);
	mixNumber(x * decrement);
	mixNumber(Number("9.999999999999999e" + k));
	mixNumber(Number("5e" + k));
}
section("powers of ten");

const twoPower52 = 4503599627370496.0;
const subnormalStep = 5e-324;
for (let i = 1; i <= 1000; i++) {
	mixNumber(subnormalStep * i);
	mixNumber(subnormalStep * (twoPower52 - 1000.0 + i));
	mixNumber(2.2250738585072014e-308 + subnormalStep * i);
}
section("subnormals");

for (let i = 0; i < 5000; i++) {
	const high = next() % 2097152.0;
	const low = next() % 4294967296.0;
	const mantissa = twoPower52 + high * 4294967296.0 + low;
	const e = (next() % 2046.0) - 1022.0;
	const scale = e < 0.0 ? inversePowersOfTwo[(-e) as int32] : powersOfTwo[e as int32];
	mixNumber(mantissa * scale / twoPower52);
}
section("random mantissa and exponent");

const tenPowers: float64[] = [];
let ten = 1.0;
for (let i = 0; i <= 14; i++) {
	tenPowers.push(ten);
	ten *= 10.0;
}
for (let i = 0; i < 4000; i++) {
	const digits = next() * 100.0 + next() % 100.0;
	const places = (next() % 15.0) as int32;
	mixNumber(digits / tenPowers[places]);
	mixNumber(digits * tenPowers[places]);
}
section("short decimals");

for (let i = 0; i < 1000; i++) {
	const magnitude = (next() % 3.0 + 1.0) * 1000000.0 * (next() % 1000000000.0);
	mixNumber(magnitude);
	mixNumber(-magnitude);
}
for (let i = -600; i <= 600; i++) {
	mixNumber(i as float64);
	mixNumber(9007199254740992.0 + (i as float64) * 2.0);
	mixNumber(1000000000000000.0 + (i as float64));
	mixNumber(-1000000000000000.0 - (i as float64));
}
section("integers");

const int64Values: int64[] = [
	0, 1, -1, 9, 10, 99, 100, 2147483647, -2147483648, 4294967295, 9007199254740991, 9007199254740993,
	-9007199254740993, 9223372036854775807, -9223372036854775807, 1000000000000000000, -1000000000000000000,
];
for (const value of int64Values) mix(`${value}`);
section("int64");

const uint64Values: uint64[] = [
	0, 1, 9, 10, 99, 100, 4294967295, 9007199254740993, 9223372036854775807, 9223372036854775808,
	10000000000000000000, 18446744073709551615,
];
for (const value of uint64Values) mix(`${value}`);
section("uint64");

console.log(`${true} ${false} ${5e-324} ${-0.0} ${1e21} ${0.000001} ${123456789.125} ${NaN} ${-Infinity}`);
