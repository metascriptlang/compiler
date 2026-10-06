struct FieldElement {
	limbs: uint64[16];
}

const LIMB_MASK: uint64 = 0xffff;

function zero(): FieldElement {
	return { limbs: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0] };
}

function small(value: uint64): FieldElement {
	let element = zero();
	element.limbs[0] = value;
	return element;
}

function edwardsD(): FieldElement {
	return {
		limbs: [
			0x78a3, 0x1359, 0x4dca, 0x75eb, 0xd8ab, 0x4141, 0x0a4d, 0x0070,
			0xe898, 0x7779, 0x4079, 0x8cc7, 0xfe73, 0x2b6f, 0x6cee, 0x5203,
		],
	};
}

function carried(element: FieldElement): FieldElement {
	let out = element;
	for (let round = 0; round < 2; round++) {
		for (let i = 0; i < 15; i++) {
			out.limbs[i + 1] += out.limbs[i] >> 16;
			out.limbs[i] &= LIMB_MASK;
		}
		out.limbs[0] += 38 * (out.limbs[15] >> 16);
		out.limbs[15] &= LIMB_MASK;
	}
	return out;
}

function plus(a: FieldElement, b: FieldElement): FieldElement {
	let out = zero();
	for (let i = 0; i < 16; i++) { out.limbs[i] = a.limbs[i] + b.limbs[i]; }
	return carried(out);
}

function minus(a: FieldElement, b: FieldElement): FieldElement {
	let out = zero();
	out.limbs[0] = a.limbs[0] + 0x1ffb4 - b.limbs[0];
	for (let i = 1; i < 16; i++) { out.limbs[i] = a.limbs[i] + 0x1fffe - b.limbs[i]; }
	return carried(out);
}

function times(a: FieldElement, b: FieldElement): FieldElement {
	let wide: uint64[31] = [];
	for (let i = 0; i < 16; i++) {
		for (let j = 0; j < 16; j++) { wide[i + j] += a.limbs[i] * b.limbs[j]; }
	}
	let out = zero();
	for (let i = 0; i < 15; i++) { out.limbs[i] = wide[i] + 38 * wide[i + 16]; }
	out.limbs[15] = wide[15];
	return carried(out);
}

function canonical(element: FieldElement): FieldElement {
	let out = carried(element);
	for (let round = 0; round < 2; round++) {
		for (let i = 0; i < 15; i++) {
			out.limbs[i + 1] += out.limbs[i] >> 16;
			out.limbs[i] &= LIMB_MASK;
		}
		out.limbs[0] += 38 * (out.limbs[15] >> 16);
		out.limbs[15] &= LIMB_MASK;
	}
	for (let round = 0; round < 2; round++) {
		let borrow: uint64 = 0;
		let reduced = zero();
		for (let i = 0; i < 16; i++) {
			const prime: uint64 = i == 0 ? 0xffed : (i == 15 ? 0x7fff : 0xffff);
			const owed = prime + borrow;
			if (out.limbs[i] >= owed) {
				reduced.limbs[i] = out.limbs[i] - owed;
				borrow = 0;
			} else {
				reduced.limbs[i] = out.limbs[i] + 0x10000 - owed;
				borrow = 1;
			}
		}
		if (borrow == 0) { out = reduced; }
	}
	return out;
}

function equalsSmall(element: FieldElement, value: uint64): boolean {
	const reduced = canonical(element);
	if (reduced.limbs[0] != value) { return false; }
	for (let i = 1; i < 16; i++) {
		if (reduced.limbs[i] != 0) { return false; }
	}
	return true;
}

export function isEdwardsPoint(point: Readonly<Span<uint8>>): boolean {
	if (point.length != 32) { return false; }
	let y = zero();
	for (let i = 0; i < 16; i++) {
		y.limbs[i] = (point[2 * i] as uint64) | ((point[2 * i + 1] as uint64) << 8);
	}
	y.limbs[15] &= 0x7fff;
	const one = small(1);
	const ySquared = times(y, y);
	const u = minus(ySquared, one);
	const v = plus(times(edwardsD(), ySquared), one);
	const ratio = times(u, v);
	let character = one;
	for (let bit = 253; bit >= 0; bit--) {
		character = times(character, character);
		if (bit != 0 && bit != 3) { character = times(character, ratio); }
	}
	return equalsSmall(character, 0) || equalsSmall(character, 1);
}

function hexBytes(hex: string): uint8[] {
	let bytes: uint8[] = [];
	const digits = "0123456789abcdef";
	for (let i = 0; i + 1 < hex.length; i += 2) {
		const high = digits.indexOf(hex.slice(i, i + 1));
		const low = digits.indexOf(hex.slice(i + 1, i + 2));
		bytes.push((high * 16 + low) as uint8);
	}
	return bytes;
}

test "edwards d is -121665/121666" {
	assert equalsSmall(plus(times(edwardsD(), small(121666)), small(121665)), 0);
}

test "the base point and the identity are points" {
	assert isEdwardsPoint(hexBytes("5866666666666666666666666666666666666666666666666666666666666666"));
	assert isEdwardsPoint(hexBytes("0100000000000000000000000000000000000000000000000000000000000000"));
	assert !isEdwardsPoint(hexBytes("0200000000000000000000000000000000000000000000000000000000000000"));
}

test "a y of p or above is reduced, as the runtime's point validation reduces it" {
	assert isEdwardsPoint(hexBytes("ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f"));
	assert isEdwardsPoint(hexBytes("edffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f"));
	assert isEdwardsPoint(hexBytes("eeffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f"));
	assert isEdwardsPoint(hexBytes("ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f"));
}

test "the sign bit is ignored, as the runtime's point validation ignores it, even where x is zero" {
	assert isEdwardsPoint(hexBytes("0100000000000000000000000000000000000000000000000000000000000080"));
	assert isEdwardsPoint(hexBytes("0000000000000000000000000000000000000000000000000000000000000000"));
}

test "random encodings agree with Euler's criterion" {
	assert !isEdwardsPoint(hexBytes("468b4b6627188d8505171cb7498948bce271a46996b4db613ae202e3265d675e"));
	assert isEdwardsPoint(hexBytes("4b60464b260dc537f5c228f8424ffc9db6c585b6c67f3b03c1be2c85799f226c"));
	assert isEdwardsPoint(hexBytes("c991525c3e4210f99c05a20d6e110ed2a26dee12e7ab2e96c17fc388f7112dbb"));
	assert !isEdwardsPoint(hexBytes("00cec9eef1924d5194ecf24f44be4c2a0406c246895c03462dec5b0a3fb9733d"));
	assert isEdwardsPoint(hexBytes("f4e13540584da8a8f1dd99a6e656b4cb9392ac9d0a9d1ce8e1acd46c24d94a49"));
	assert isEdwardsPoint(hexBytes("5098f232268c93cc9e67a17bb48af2cb00b070dcfef34ddd23c614c092403e70"));
	assert isEdwardsPoint(hexBytes("635e7c4552123d8240bd20df0d4dc331edd157cf71f14e1265fa6fbaaf598d75"));
	assert !isEdwardsPoint(hexBytes("0187060a806ae0108ee0557df3c1b5027810cf16f45d7a604757c1b41578a5de"));
	assert !isEdwardsPoint(hexBytes("3eaa87627774887df18d259abea2766bb99652f8d10615330194d54ebd103c99"));
	assert !isEdwardsPoint(hexBytes("7e4462eedbc2f5bee1ab7ff10345495991312d42cca7f4321f917b6694d300a5"));
	assert isEdwardsPoint(hexBytes("8c7d3f8f443d2f7f8db9aff6640280ad4e0033b58b6209cdad3a0506dc7fe917"));
	assert !isEdwardsPoint(hexBytes("700d36de43897fe2f0c16c3368b9c933a4bd1c8794ba1b21d0e3d5512ee00dfd"));
}

test "a length other than 32 is not a point" {
	assert !isEdwardsPoint(hexBytes("01"));
}

test "the check runs at compile time" {
	const base = @comptime { return isEdwardsPoint(hexBytes("5866666666666666666666666666666666666666666666666666666666666666")); };
	const two = @comptime { return isEdwardsPoint(hexBytes("0200000000000000000000000000000000000000000000000000000000000000")); };
	assert base && !two;
}
