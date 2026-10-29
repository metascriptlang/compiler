const limbBase: int64 = 1000000000;
const twoPow53: float64 = 9007199254740992.0;
const fixedTextLimit: float64 = 1e21;

function mulSmall(limbs: int64[], k: int64): void {
	let carry: int64 = 0;
	for (let i = 0; i < limbs.length; i++) {
		const cur = limbs[i] * k + carry;
		limbs[i] = cur % limbBase;
		carry = cur / limbBase;
	}
	while (carry > 0) {
		limbs.push(carry % limbBase);
		carry /= limbBase;
	}
}

function divSmall(limbs: int64[], d: int64): void {
	let rest: int64 = 0;
	for (let i = limbs.length - 1; i >= 0; i--) {
		const cur = rest * limbBase + limbs[i];
		limbs[i] = cur / d;
		rest = cur % d;
	}
	while (limbs.length > 0 && limbs[limbs.length - 1] == 0) limbs.pop();
}

function addOne(limbs: int64[]): void {
	for (let i = 0; i < limbs.length; i++) {
		limbs[i] += 1;
		if (limbs[i] < limbBase) return;
		limbs[i] = 0;
	}
	limbs.push(1);
}

function limbsText(limbs: int64[]): string {
	if (limbs.length == 0) return "0";
	let text = `${limbs[limbs.length - 1]}`;
	for (let i = limbs.length - 2; i >= 0; i--) {
		const part = `${limbs[i]}`;
		text += "0".repeat(9 - part.length) + part;
	}
	return text;
}

export function checkedFixedDigits(digits: int32): int32 {
	if (digits < 0 || digits > 100) {
		throw new RangeError("toFixed() digits argument must be between 0 and 100");
	}
	return digits;
}

function scaledRoundedText(v: float64, digits: int32): string {
	let m = v;
	let e = 0;
	while (m >= twoPow53) {
		m /= 2.0;
		e += 1;
	}
	while (m != Math.floor(m)) {
		m *= 2.0;
		e -= 1;
	}
	const mi = m as int64;
	const limbs: int64[] = [];
	if (mi > 0) {
		limbs.push(mi % limbBase);
		if (mi >= limbBase) limbs.push(mi / limbBase);
	}
	let tens = digits;
	while (tens > 0) {
		const step = tens < 9 ? tens : 9;
		let scale: int64 = 1;
		for (let i = 0; i < step; i++) scale *= 10;
		mulSmall(limbs, scale);
		tens -= step;
	}
	if (e >= 0) {
		let twos = e;
		while (twos > 0) {
			const step = twos < 29 ? twos : 29;
			mulSmall(limbs, (1 as int64) << (step as int64));
			twos -= step;
		}
	} else {
		let twos = -e - 1;
		while (twos > 0 && limbs.length > 0) {
			const step = twos < 29 ? twos : 29;
			divSmall(limbs, (1 as int64) << (step as int64));
			twos -= step;
		}
		if (limbs.length > 0) {
			addOne(limbs);
			divSmall(limbs, 2);
		}
	}
	return limbsText(limbs);
}

export function float64FixedText(value: float64, digits: int32): string {
	const f = checkedFixedDigits(digits);
	if (value != value || value >= fixedTextLimit || value <= -fixedTextLimit) return `${value}`;
	const negative = value < 0.0;
	let text = scaledRoundedText(negative ? -value : value, f);
	if (f > 0) {
		if (text.length <= f) text = "0".repeat(f + 1 - text.length) + text;
		text = text.byteSlice(0, text.length - f) + "." + text.byteSlice(text.length - f, text.length);
	}
	return negative ? "-" + text : text;
}
