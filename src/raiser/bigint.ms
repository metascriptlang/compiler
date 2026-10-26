// Arbitrary-precision integers for the Raiser VM, with the semantics of runtime/bigint/bigint.c.
// A VM bigint is a string cell holding its canonical text: an optional "-" and lowercase
// hexadecimal digits without leading zeros ("0" for zero). Strings are the VM's existing
// counted immutable cell, so copy, destroy and the ledger need nothing new, and every
// operation here maps text to text.

const LIMB_BASE: int64 = 65536;
const DIGITS = "0123456789abcdefghijklmnopqrstuvwxyz";
const FLOAT32_MAX: float64 = 3.4028234663852886e38;
const MAX_SHIFT: int64 = 1099511627776;

interface BigNum {
	neg: boolean;
	mag: int32[];
}

function make(neg: boolean, mag: int32[]): BigNum {
	trim(mag);
	return { neg: neg && mag.length > 0, mag };
}

function trim(mag: int32[]): void {
	while (mag.length > 0 && mag[mag.length - 1] == 0) mag.pop();
}

function copyMag(mag: int32[]): int32[] {
	const out: int32[] = [];
	for (const limb of mag) out.push(limb);
	return out;
}

function fail(message: string): never {
	throw new Error(message);
}

function cmpMag(a: int32[], b: int32[]): int32 {
	if (a.length != b.length) return a.length < b.length ? -1 : 1;
	for (let i = a.length - 1; i >= 0; i -= 1) {
		if (a[i] != b[i]) return a[i] < b[i] ? -1 : 1;
	}
	return 0;
}

function addMag(a: int32[], b: int32[]): int32[] {
	const out: int32[] = [];
	let carry: int64 = 0;
	const n = a.length > b.length ? a.length : b.length;
	for (let i = 0; i < n; i += 1) {
		const sum = carry + (i < a.length ? a[i] as int64 : 0) + (i < b.length ? b[i] as int64 : 0);
		out.push((sum % LIMB_BASE) as int32);
		carry = sum / LIMB_BASE;
	}
	if (carry > 0) out.push(carry as int32);
	return out;
}

function subMag(a: int32[], b: int32[]): int32[] {
	const out: int32[] = [];
	let borrow: int64 = 0;
	for (let i = 0; i < a.length; i += 1) {
		let diff = (a[i] as int64) - borrow - (i < b.length ? b[i] as int64 : 0);
		if (diff < 0) {
			diff += LIMB_BASE;
			borrow = 1;
		} else {
			borrow = 0;
		}
		out.push(diff as int32);
	}
	trim(out);
	return out;
}

function mulMag(a: int32[], b: int32[]): int32[] {
	if (a.length == 0 || b.length == 0) return [];
	const acc: int64[] = [];
	for (let i = 0; i < a.length + b.length; i += 1) acc.push(0);
	for (let i = 0; i < a.length; i += 1) {
		let carry: int64 = 0;
		for (let j = 0; j < b.length; j += 1) {
			const cur = acc[i + j] + (a[i] as int64) * (b[j] as int64) + carry;
			acc[i + j] = cur % LIMB_BASE;
			carry = cur / LIMB_BASE;
		}
		acc[i + b.length] += carry;
	}
	const out: int32[] = [];
	for (const limb of acc) out.push(limb as int32);
	trim(out);
	return out;
}

function mulSmallAdd(mag: int32[], factor: int64, addend: int64): void {
	let carry = addend;
	for (let i = 0; i < mag.length; i += 1) {
		const cur = (mag[i] as int64) * factor + carry;
		mag[i] = (cur % LIMB_BASE) as int32;
		carry = cur / LIMB_BASE;
	}
	while (carry > 0) {
		mag.push((carry % LIMB_BASE) as int32);
		carry = carry / LIMB_BASE;
	}
}

// Divides in place by a divisor below LIMB_BASE and returns the remainder.
function divSmall(mag: int32[], divisor: int64): int64 {
	let rem: int64 = 0;
	for (let i = mag.length - 1; i >= 0; i -= 1) {
		const cur = rem * LIMB_BASE + (mag[i] as int64);
		mag[i] = (cur / divisor) as int32;
		rem = cur % divisor;
	}
	trim(mag);
	return rem;
}

function shlMag(mag: int32[], bits: int64): int32[] {
	if (mag.length == 0) return [];
	const out: int32[] = [];
	for (let i = 0; i < bits / 16; i += 1) out.push(0);
	const inner = bits % 16;
	let carry: int64 = 0;
	for (const limb of mag) {
		const cur = ((limb as int64) << inner) | carry;
		out.push((cur % LIMB_BASE) as int32);
		carry = cur / LIMB_BASE;
	}
	if (carry > 0) out.push(carry as int32);
	return out;
}

function shrMag(mag: int32[], bits: int64): int32[] {
	const skip = bits / 16;
	if (skip >= mag.length) return [];
	const inner = bits % 16;
	const out: int32[] = [];
	for (let i = skip as int32; i < mag.length; i += 1) {
		const next = i + 1 < mag.length ? mag[i + 1] as int64 : 0;
		out.push(((((mag[i] as int64) | (next << 16)) >> inner) % LIMB_BASE) as int32);
	}
	trim(out);
	return out;
}

function bitLength(mag: int32[]): int64 {
	if (mag.length == 0) return 0;
	let top = mag[mag.length - 1];
	let bits = 0;
	while (top > 0) {
		bits += 1;
		top = top >> 1;
	}
	return ((mag.length - 1) * 16 + bits) as int64;
}

function bitAt(mag: int32[], index: int64): int32 {
	const limb = index / 16;
	if (limb >= mag.length) return 0;
	return (mag[limb as int32] >> ((index % 16) as int32)) & 1;
}

function lowestSetBit(mag: int32[]): int64 {
	for (let i = 0; i < mag.length; i += 1) {
		if (mag[i] != 0) {
			let bit = 0;
			while (((mag[i] >> bit) & 1) == 0) bit += 1;
			return (i * 16 + bit) as int64;
		}
	}
	return 0;
}

// Truncating division, as JS `/` and `%` on bigint: the remainder takes the dividend's sign.
function divModMag(a: int32[], b: int32[]): int32[][] {
	if (cmpMag(a, b) < 0) return [[], copyMag(a)];
	if (b.length == 1) {
		const q = copyMag(a);
		const r = divSmall(q, b[0] as int64);
		return [q, r == 0 ? [] : [r as int32]];
	}
	const n = b.length;
	const m = a.length - n;
	let norm: int64 = 0;
	let probe = b[n - 1];
	while (probe < 32768) {
		probe = probe << 1;
		norm += 1;
	}
	const v = shlMag(b, norm);
	const u = shlMag(a, norm);
	while (u.length < a.length + 1) u.push(0);
	const q: int32[] = [];
	for (let i = 0; i <= m; i += 1) q.push(0);
	const vTop = v[n - 1] as int64;
	const vNext = v[n - 2] as int64;
	for (let j = m; j >= 0; j -= 1) {
		const num = (u[j + n] as int64) * LIMB_BASE + (u[j + n - 1] as int64);
		let qhat = num / vTop;
		let rhat = num % vTop;
		while (qhat >= LIMB_BASE || qhat * vNext > rhat * LIMB_BASE + (u[j + n - 2] as int64)) {
			qhat -= 1;
			rhat += vTop;
			if (rhat >= LIMB_BASE) break;
		}
		let borrow: int64 = 0;
		let carry: int64 = 0;
		for (let i = 0; i < n; i += 1) {
			const product = qhat * (v[i] as int64) + carry;
			carry = product / LIMB_BASE;
			let diff = (u[i + j] as int64) - borrow - (product % LIMB_BASE);
			if (diff < 0) {
				diff += LIMB_BASE;
				borrow = 1;
			} else {
				borrow = 0;
			}
			u[i + j] = diff as int32;
		}
		let last = (u[j + n] as int64) - borrow - carry;
		if (last < 0) {
			last += LIMB_BASE;
			borrow = 1;
		} else {
			borrow = 0;
		}
		u[j + n] = last as int32;
		if (borrow != 0) {
			qhat -= 1;
			let add: int64 = 0;
			for (let i = 0; i < n; i += 1) {
				const sum = (u[i + j] as int64) + (v[i] as int64) + add;
				u[i + j] = (sum % LIMB_BASE) as int32;
				add = sum / LIMB_BASE;
			}
			u[j + n] = (((u[j + n] as int64) + add) % LIMB_BASE) as int32;
		}
		q[j] = qhat as int32;
	}
	trim(q);
	const rem: int32[] = [];
	for (let i = 0; i < n; i += 1) rem.push(u[i]);
	trim(rem);
	return [q, shrMag(rem, norm)];
}

function zero(): BigNum {
	return make(false, []);
}

function fromInt64Value(v: int64): BigNum {
	if (v == 0) return zero();
	const neg = v < 0;
	const mag: int32[] = [];
	let rest = neg ? (0 - v) as uint64 : v as uint64;
	while (rest > 0) {
		mag.push((rest % 65536) as int32);
		rest = rest / 65536;
	}
	return make(neg, mag);
}

function fromUint64Value(v: uint64): BigNum {
	const mag: int32[] = [];
	let rest = v;
	while (rest > 0) {
		mag.push((rest % 65536) as int32);
		rest = rest / 65536;
	}
	return make(false, mag);
}

function addSigned(a: BigNum, b: BigNum): BigNum {
	if (a.neg == b.neg) return make(a.neg, addMag(a.mag, b.mag));
	const order = cmpMag(a.mag, b.mag);
	if (order == 0) return zero();
	if (order > 0) return make(a.neg, subMag(a.mag, b.mag));
	return make(b.neg, subMag(b.mag, a.mag));
}

function negate(a: BigNum): BigNum {
	return make(!a.neg, copyMag(a.mag));
}

function compare(a: BigNum, b: BigNum): int32 {
	if (a.neg != b.neg) return a.neg ? -1 : 1;
	const order = cmpMag(a.mag, b.mag);
	return a.neg ? -order : order;
}

// ===== text form =====

function hexText(a: BigNum): string {
	if (a.mag.length == 0) return "0";
	let text = "";
	for (let i = a.mag.length - 1; i >= 0; i -= 1) {
		const limb = a.mag[i];
		for (let shift = 12; shift >= 0; shift -= 4) {
			text += DIGITS[(limb >> shift) & 15];
		}
	}
	let start = 0;
	while (start < text.length - 1 && text[start] == "0") start += 1;
	return (a.neg ? "-" : "") + text.slice(start, text.length);
}

function digitValue(c: string): int32 {
	const code = c.charCodeAt(0);
	if (code >= 48 && code <= 57) return code - 48;
	if (code >= 97 && code <= 122) return code - 87;
	if (code >= 65 && code <= 90) return code - 55;
	return 99;
}

function parseDigits(text: string, radix: int32): int32[] | null {
	if (text.length == 0) return null;
	const mag: int32[] = [];
	for (let i = 0; i < text.length; i += 1) {
		const d = digitValue(text[i]);
		if (d >= radix) return null;
		mulSmallAdd(mag, radix as int64, d as int64);
	}
	trim(mag);
	return mag;
}

function read(text: string): BigNum {
	const neg = text.startsWith("-");
	const digits = neg ? text.slice(1, text.length) : text;
	const mag = parseDigits(digits, 16);
	if (mag == null) fail(`internal: a bigint cell holds '${text}'`);
	return make(neg, mag);
}

function radixText(a: BigNum, radix: int32): string {
	if (a.mag.length == 0) return "0";
	const work = copyMag(a.mag);
	let reversed = "";
	while (work.length > 0) reversed += DIGITS[divSmall(work, radix as int64) as int32];
	let text = a.neg ? "-" : "";
	for (let i = reversed.length - 1; i >= 0; i -= 1) text += reversed[i];
	return text;
}

function isSpace(c: string): boolean {
	return c == " " || c == "\t" || c == "\n" || c == "\r" || c == "\v" || c == "\f";
}

function trimmed(text: string): string {
	let start = 0;
	let end = text.length;
	while (start < end && isSpace(text[start])) start += 1;
	while (end > start && isSpace(text[end - 1])) end -= 1;
	return text.slice(start, end);
}

function radixOfPrefix(text: string): int32 {
	if (text.length < 2 || text[0] != "0") return 10;
	const c = text[1].toLowerCase();
	return c == "x" ? 16 : c == "o" ? 8 : c == "b" ? 2 : 10;
}

// What a source literal or a string cast reads: surrounding spaces, a trailing `n`, a sign,
// a radix prefix and `_` separators.
export function bigFromLit(text: string): string {
	let body = trimmed(text);
	if (body.endsWith("n")) body = body.slice(0, body.length - 1);
	let neg = false;
	if (body.startsWith("-") || body.startsWith("+")) {
		neg = body[0] == "-";
		body = body.slice(1, body.length);
	}
	const radix = radixOfPrefix(body);
	if (radix != 10) body = body.slice(2, body.length);
	let clean = "";
	for (let i = 0; i < body.length; i += 1) {
		if (body[i] != "_") clean += body[i];
	}
	if (clean.length == 0) {
		if (neg) fail("BigInt: cannot convert string to a BigInt");
		return "0";
	}
	const mag = parseDigits(clean, radix);
	if (mag == null) fail("BigInt: cannot convert string to a BigInt");
	return hexText(make(neg, mag));
}

// The syntax `BigInt(text)` accepts: empty is zero, a radix prefix takes no sign.
function parseStrict(text: string): BigNum | null {
	let body = trimmed(text);
	if (body.length == 0) return zero();
	let radix = radixOfPrefix(body);
	let neg = false;
	if (radix != 10) {
		body = body.slice(2, body.length);
	} else if (body.startsWith("-") || body.startsWith("+")) {
		neg = body[0] == "-";
		body = body.slice(1, body.length);
	}
	const mag = parseDigits(body, radix);
	return mag == null ? null : make(neg, mag);
}

export function bigParses(text: string): boolean {
	return parseStrict(text) != null;
}

export function bigParse(text: string): string {
	const parsed = parseStrict(text);
	if (parsed == null) fail("BigInt: cannot convert string to a BigInt");
	return hexText(parsed);
}

export function bigToString(a: string, radix: int32): string {
	if (radix < 2 || radix > 36) fail("BigInt: toString() radix must be between 2 and 36");
	return radixText(read(a), radix);
}

export function bigToDebug(a: string): string {
	return radixText(read(a), 10) + "n";
}

// ===== conversions =====

export function bigFromInt64(v: int64): string {
	return hexText(fromInt64Value(v));
}

export function bigFromUint64(v: int64): string {
	return hexText(fromUint64Value(v as uint64));
}

export function bigFromFloat64(v: float64): string {
	if (v != v || v == Infinity || v == -Infinity || Math.trunc(v) != v) {
		fail("BigInt: the number cannot be converted to a BigInt because it is not an integer");
	}
	const mag: int32[] = [];
	let rest = v < 0.0 ? -v : v;
	while (rest > 0.0) {
		const limb = rest % 65536.0;
		mag.push(limb as int32);
		rest = (rest - limb) / 65536.0;
	}
	return hexText(make(v < 0.0, mag));
}

export function bigToFloat64(a: string): float64 {
	return radixText(read(a), 10).parseFloat();
}

function wrapped(a: BigNum, bits: int64): BigNum {
	if (bits == 0) return zero();
	const modulus = shlMag([1], bits);
	const parts = divModMag(a.mag, modulus);
	const rem = make(a.neg, parts[1]);
	if (!rem.neg) return rem;
	return make(false, subMag(modulus, rem.mag));
}

function wrappedSigned(a: BigNum, bits: int64): BigNum {
	const unsigned = wrapped(a, bits);
	if (bits == 0) return unsigned;
	if (bitLength(unsigned.mag) < bits) return unsigned;
	return make(true, subMag(shlMag([1], bits), unsigned.mag));
}

export function bigAsUintN(bits: int64, a: string): string {
	if (bits < 0) fail("BigInt: asUintN bits must be non-negative");
	return hexText(wrapped(read(a), bits));
}

export function bigAsIntN(bits: int64, a: string): string {
	if (bits < 0) fail("BigInt: asIntN bits must be non-negative");
	return hexText(wrappedSigned(read(a), bits));
}

export function bigToInt64(a: string): int64 {
	const low = wrappedSigned(read(a), 64);
	let value: int64 = 0;
	for (let i = low.mag.length - 1; i >= 0; i -= 1) {
		value = low.neg ? value * LIMB_BASE - (low.mag[i] as int64) : value * LIMB_BASE + (low.mag[i] as int64);
	}
	return value;
}

export function bigToSigned(a: string, bits: int32): int64 {
	const value = read(a);
	const width = (bits - 1) as int64;
	const n = bitLength(value.mag);
	const fits = n <= width || (value.neg && n == width + 1 && lowestSetBit(value.mag) == width);
	if (!fits) {
		const bound = bigShl(bigFromInt64(1), bigFromInt64(width));
		fail(`value ${radixText(value, 10)} not in range ${bigToString(bigNeg(bound), 10)} .. ${bigToString(bigSub(bound, bigFromInt64(1)), 10)}`);
	}
	return bigToInt64(a);
}

export function bigToFloat32(a: string): float64 {
	const value = read(a);
	const n = bitLength(value.mag);
	if (n <= 24) return bigToInt64(a) as float64;
	const shift = n - 24;
	let m: int64 = 0;
	for (let i = n - 1; i >= shift; i -= 1) m = m * 2 + (bitAt(value.mag, i) as int64);
	const half = bitAt(value.mag, shift - 1) == 1;
	const sticky = lowestSetBit(value.mag) < shift - 1;
	if (half && (sticky || (m & 1) != 0)) m += 1;
	let result = shift > 128 ? Infinity : (m as float64) * Math.pow(2.0, shift as float64);
	if (result > FLOAT32_MAX) result = Infinity;
	return value.neg ? -result : result;
}

// ===== arithmetic =====

export function bigAdd(a: string, b: string): string {
	return hexText(addSigned(read(a), read(b)));
}

export function bigSub(a: string, b: string): string {
	return hexText(addSigned(read(a), negate(read(b))));
}

export function bigMul(a: string, b: string): string {
	const x = read(a);
	const y = read(b);
	return hexText(make(x.neg != y.neg, mulMag(x.mag, y.mag)));
}

function divided(a: string, b: string): int32[][] {
	const divisor = read(b);
	if (divisor.mag.length == 0) fail("BigInt: division by zero");
	return divModMag(read(a).mag, divisor.mag);
}

export function bigDiv(a: string, b: string): string {
	const x = read(a);
	const y = read(b);
	return hexText(make(x.neg != y.neg, divided(a, b)[0]));
}

export function bigMod(a: string, b: string): string {
	return hexText(make(read(a).neg, divided(a, b)[1]));
}

export function bigPow(a: string, b: string): string {
	const exponent = read(b);
	if (exponent.neg) fail("BigInt: exponent must be non-negative");
	const base = read(a);
	let result: int32[] = [1];
	for (let i = bitLength(exponent.mag) - 1; i >= 0; i -= 1) {
		result = mulMag(result, result);
		if (bitAt(exponent.mag, i) == 1) result = mulMag(result, base.mag);
	}
	const odd = exponent.mag.length > 0 && (exponent.mag[0] & 1) == 1;
	return hexText(make(base.neg && odd, result));
}

export function bigNeg(a: string): string {
	return hexText(negate(read(a)));
}

export function bigNot(a: string): string {
	return hexText(negate(addSigned(read(a), fromInt64Value(1))));
}

export function bigCmp(a: string, b: string): int32 {
	return compare(read(a), read(b));
}

export function bigIsZero(a: string): boolean {
	return read(a).mag.length == 0;
}

export function bigCompareFloat64(a: string, d: float64, unordered: int32): int32 {
	if (d != d) return unordered;
	if (d == Infinity || d == -Infinity) return d > 0.0 ? -1 : 1;
	const whole = Math.floor(d);
	const order = bigCmp(a, bigFromFloat64(whole));
	if (order != 0) return order;
	return whole == d ? 0 : -1;
}

export function float64CompareBig(d: float64, a: string, unordered: int32): int32 {
	if (d != d) return unordered;
	return -bigCompareFloat64(a, d, 0);
}

// ===== bitwise and shifts: two's complement over unbounded width =====

function twosComplement(a: BigNum, limbs: int32): int32[] {
	const out: int32[] = [];
	for (let i = 0; i < limbs; i += 1) out.push(i < a.mag.length ? a.mag[i] : 0);
	if (!a.neg) return out;
	let carry = 1;
	for (let i = 0; i < limbs; i += 1) {
		const sum = (65535 - out[i]) + carry;
		out[i] = sum % 65536;
		carry = sum >> 16;
	}
	return out;
}

function fromTwosComplement(limbs: int32[]): BigNum {
	if (limbs[limbs.length - 1] < 32768) return make(false, limbs);
	let carry = 1;
	for (let i = 0; i < limbs.length; i += 1) {
		const sum = (65535 - limbs[i]) + carry;
		limbs[i] = sum % 65536;
		carry = sum >> 16;
	}
	return make(true, limbs);
}

function bitwise(a: string, b: string, op: int32): string {
	const x = read(a);
	const y = read(b);
	const count = (x.mag.length > y.mag.length ? x.mag.length : y.mag.length) + 1;
	const left = twosComplement(x, count);
	const right = twosComplement(y, count);
	for (let i = 0; i < count; i += 1) {
		left[i] = op == 0 ? left[i] & right[i] : op == 1 ? left[i] | right[i] : left[i] ^ right[i];
	}
	return hexText(fromTwosComplement(left));
}

export function bigAnd(a: string, b: string): string {
	return bitwise(a, b, 0);
}

export function bigOr(a: string, b: string): string {
	return bitwise(a, b, 1);
}

export function bigXor(a: string, b: string): string {
	return bitwise(a, b, 2);
}

function shiftCount(b: BigNum): int64 {
	if (b.mag.length > 4) fail("BigInt: shift count too large");
	let count: int64 = 0;
	for (let i = b.mag.length - 1; i >= 0; i -= 1) count = count * LIMB_BASE + (b.mag[i] as int64);
	if (count > MAX_SHIFT) fail("BigInt: shift count too large");
	return count;
}

function shiftLeft(a: BigNum, n: int64): BigNum {
	return make(a.neg, shlMag(a.mag, n));
}

function shiftRight(a: BigNum, n: int64): BigNum {
	const kept = shrMag(a.mag, n);
	if (!a.neg) return make(false, kept);
	const lost = cmpMag(shlMag(kept, n), a.mag) != 0;
	return make(true, lost ? addMag(kept, [1]) : kept);
}

export function bigShl(a: string, b: string): string {
	const count = read(b);
	const n = shiftCount(count);
	return hexText(count.neg ? shiftRight(read(a), n) : shiftLeft(read(a), n));
}

export function bigShr(a: string, b: string): string {
	const count = read(b);
	const n = shiftCount(count);
	return hexText(count.neg ? shiftLeft(read(a), n) : shiftRight(read(a), n));
}

// ===== tests =====

function dec(text: string): string {
	return bigToString(bigFromLit(text), 10);
}

test "a literal round-trips through the canonical text in every radix" {
	assert bigFromLit("255n") == "ff";
	assert bigFromLit("0xffn") == "ff";
	assert bigFromLit("-0b101") == "-5";
	assert bigFromLit("1_000") == "3e8";
	assert bigFromLit("0") == "0";
	assert bigToString("-ff", 10) == "-255";
	assert bigToString("ff", 2) == "11111111";
	assert bigToString("ff", 36) == "73";
	assert dec("123456789012345678901234567890") == "123456789012345678901234567890";
}

test "arithmetic follows truncated division and carries across limbs" {
	const big = bigFromLit("123456789012345678901234567890");
	assert bigToString(bigMul(big, big), 10) == "15241578753238836750495351562536198787501905199875019052100";
	assert bigToString(bigDiv(bigMul(big, big), big), 10) == "123456789012345678901234567890";
	assert bigToString(bigMod(bigAdd(bigMul(big, big), "5"), big), 10) == "5";
	assert dec("-7") == "-7";
	assert bigToString(bigDiv(bigFromLit("-7"), bigFromLit("2")), 10) == "-3";
	assert bigToString(bigMod(bigFromLit("-7"), bigFromLit("2")), 10) == "-1";
	assert bigToString(bigSub(bigFromLit("5"), bigFromLit("12")), 10) == "-7";
	assert bigToString(bigPow(bigFromLit("2"), bigFromLit("100")), 10) == "1267650600228229401496703205376";
	assert bigToString(bigPow(bigFromLit("-3"), bigFromLit("3")), 10) == "-27";
}

test "division by a multi-limb divisor agrees with multiplication" {
	const a = bigFromLit("98765432109876543210987654321098765432109876543210");
	const b = bigFromLit("12345678901234567890123456789");
	const q = bigDiv(a, b);
	const r = bigMod(a, b);
	assert bigAdd(bigMul(q, b), r) == a;
	assert bigCmp(r, b) < 0;
}

test "bitwise operators act on two's complement" {
	assert dec("-6") == "-6";
	assert bigToString(bigAnd(bigFromLit("-6"), bigFromLit("15")), 10) == "10";
	assert bigToString(bigOr(bigFromLit("-6"), bigFromLit("1")), 10) == "-5";
	assert bigToString(bigXor(bigFromLit("-1"), bigFromLit("255")), 10) == "-256";
	assert bigToString(bigNot(bigFromLit("5")), 10) == "-6";
	assert bigToString(bigShl(bigFromLit("1"), bigFromLit("70")), 10) == "1180591620717411303424";
	assert bigToString(bigShr(bigFromLit("-5"), bigFromLit("1")), 10) == "-3";
	assert bigToString(bigShr(bigFromLit("5"), bigFromLit("-2")), 10) == "20";
}

test "width conversions wrap and range-check like the runtime" {
	assert bigToString(bigAsUintN(8, bigFromLit("-1")), 10) == "255";
	assert bigToString(bigAsIntN(8, bigFromLit("200")), 10) == "-56";
	assert bigToInt64(bigFromLit("18446744073709551615")) == -1;
	assert bigToSigned(bigFromLit("-128"), 8) == -128;
	let stopped = "";
	try {
		bigToSigned(bigFromLit("128"), 8);
	} catch (e) {
		stopped = e.message;
	}
	assert stopped == "value 128 not in range -128 .. 127", stopped;
	assert bigToFloat32(bigFromLit("16777217")) == 16777216.0;
	assert bigToFloat32(bigFromLit("340282356779733661637539395458142568448")) == Infinity;
	assert bigToFloat64(bigFromLit("9007199254740995")) == 9007199254740996.0;
	assert bigToString(bigFromFloat64(1e21), 10) == "1000000000000000000000";
}

test "strict parsing refuses what BigInt(text) refuses" {
	assert bigParses("0x10");
	assert bigParses(" -12 ");
	assert bigParses("");
	assert !bigParses("-0x10");
	assert !bigParses("1_000");
	assert !bigParses("12n");
	assert !bigParses("1.5");
	assert !bigParses("0x");
	assert bigCompareFloat64(bigFromLit("2"), 2.5, 1) == -1;
	assert bigCompareFloat64(bigFromLit("-3"), -2.5, 1) == -1;
}
