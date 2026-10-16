export const radixDigits = "0123456789abcdefghijklmnopqrstuvwxyz";
export const exactIntegerLimit: float64 = 9007199254740992.0;

export function checkedRadix(radix: int32): int32 {
	if (radix < 2 || radix > 36) {
		throw new Error("toString() radix argument must be between 2 and 36");
	}
	return radix;
}

export function digitsText(digits: int32[], from: int32, to: int32, step: int32): string {
	let text = "";
	for (let i = from; i != to; i += step) text += radixDigits.byteSlice(digits[i], digits[i] + 1);
	return text;
}

export function halfUlp(v: float64): float64 {
	let binade = 1.0;
	while (binade * 2.0 <= v) binade *= 2.0;
	while (binade > v && binade > 2.2250738585072014e-308) binade /= 2.0;
	const half = binade * 1.1102230246251565e-16;
	return half > 0.0 ? half : 5e-324;
}

export function uint64RadixText(magnitude: uint64, radix: int32, negative: boolean): string {
	const r = radix as uint64;
	const digits: int32[] = [];
	let rest = magnitude;
	while (true) {
		digits.push((rest % r) as int32);
		rest /= r;
		if (rest == 0) break;
	}
	return (negative ? "-" : "") + digitsText(digits, digits.length - 1, -1, -1);
}

export function int64RadixText(v: int64, radix: int32): string {
	checkedRadix(radix);
	if (radix == 10) return `${v}`;
	if (v >= 0) return uint64RadixText(v as uint64, radix, false);
	return uint64RadixText(((-(v + 1)) as uint64) + 1, radix, true);
}

export function float64RadixText(value: float64, radix: int32): string {
	const r = checkedRadix(radix);
	if (r == 10 || value != value || value == 0.0 || value - value != 0.0) return `${value}`;
	const rf = r as float64;
	const negative = value < 0.0;
	const v = negative ? -value : value;
	let integer = Math.floor(v);
	let fraction = v - integer;
	let delta = halfUlp(v);
	const fractionDigits: int32[] = [];
	let point = false;
	if (fraction >= delta) {
		point = true;
		while (true) {
			fraction *= rf;
			delta *= rf;
			const digit = Math.floor(fraction) as int32;
			fractionDigits.push(digit);
			fraction -= digit as float64;
			const roundsUp = fraction > 0.5 || (fraction == 0.5 && (digit & 1) == 1);
			if (roundsUp && fraction + delta > 1.0) {
				while (true) {
					if (fractionDigits.length == 0) {
						point = false;
						integer += 1.0;
						break;
					}
					const last = fractionDigits.pop();
					if (last + 1 < r) {
						fractionDigits.push(last + 1);
						break;
					}
				}
				break;
			}
			if (!(fraction >= delta)) break;
		}
	}
	let zeros = "";
	while (integer / rf >= exactIntegerLimit) {
		integer /= rf;
		zeros += "0";
	}
	const integerDigits: int32[] = [];
	while (true) {
		const remainder = integer % rf;
		integerDigits.push(remainder as int32);
		integer = (integer - remainder) / rf;
		if (!(integer > 0.0)) break;
	}
	const sign = negative ? "-" : "";
	const head = sign + digitsText(integerDigits, integerDigits.length - 1, -1, -1);
	const tail = point ? "." + digitsText(fractionDigits, 0, fractionDigits.length, 1) : "";
	return head + zeros + tail;
}
