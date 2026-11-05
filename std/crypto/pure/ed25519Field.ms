/**
 * The field ed25519.ms computes in, chosen per backend: the fiat limbs of
 * ./fe25519 on C, JS BigInt on JS. On JS every 64-bit limb product compiles to
 * a BigInt call, which measured the limb field about 4x slower than BigInt
 * arithmetic itself (rtx, 2026-11-04).
 */
when (js) {
	import {
		P,
		mul,
		sqr,
		inv,
		pow2252m3,
		bigFromBytes,
		bigToBytes,
	} from "./field25519";

	export type Fe = bigint;

	export const feZero: Fe = 0n;
	export const feOne: Fe = 1n;

	export function feFromBytes(bytes: Readonly<uint8[]>, from: int32): Fe {
		return (bigFromBytes(bytes, from, 32) & ((1n << 255n) - 1n)) % P;
	}

	export function feToBytes(a: Fe): uint8[] {
		return bigToBytes(a, 32);
	}

	export function feAdd(a: Fe, b: Fe): Fe {
		return (a + b) % P;
	}

	export function feSub(a: Fe, b: Fe): Fe {
		return (a + P - b) % P;
	}

	export function feAddLoose(a: Fe, b: Fe): Fe {
		return feAdd(a, b);
	}

	export function feSubLoose(a: Fe, b: Fe): Fe {
		return feSub(a, b);
	}

	export function feNeg(a: Fe): Fe {
		return (P - a) % P;
	}

	export function feMul(a: Fe, b: Fe): Fe {
		return mul(a, b);
	}

	export function feSqr(a: Fe): Fe {
		return sqr(a);
	}

	export function feMul121666(a: Fe): Fe {
		return (a * 121666n) % P;
	}

	export function fePow2252m3(a: Fe): Fe {
		return pow2252m3(a);
	}

	export function feInv(a: Fe): Fe {
		return inv(a);
	}

	export function feIsZero(a: Fe): boolean {
		return a == 0n;
	}

	export function feEqual(a: Fe, b: Fe): boolean {
		return a == b;
	}

	export function feIsNegative(a: Fe): boolean {
		return (a & 1n) == 1n;
	}

	export function feCMov(a: Fe, b: Fe, bit: uint32): Fe {
		return a ^ ((0n - BigInt(bit as int32)) & (a ^ b));
	}

	export struct Niels {
		yPlusX: Fe;
		yMinusX: Fe;
		xy2d: Fe;
	}

	export function feSelectNiels(table: Readonly<Fe[]>, row: int32, magnitude: int32, negative: uint32): Niels {
		let t: Niels = { yPlusX: feOne, yMinusX: feOne, xy2d: feZero };
		for (let j = 1; j <= 8; j++) {
			const bit = ((((magnitude ^ j) - 1) >> 31) & 1) as uint32;
			const at = 3 * (row * 8 + j - 1);
			t = {
				yPlusX: feCMov(t.yPlusX, table[at], bit),
				yMinusX: feCMov(t.yMinusX, table[at + 1], bit),
				xy2d: feCMov(t.xy2d, table[at + 2], bit),
			};
		}
		return {
			yPlusX: feCMov(t.yPlusX, t.yMinusX, negative),
			yMinusX: feCMov(t.yMinusX, t.yPlusX, negative),
			xy2d: feCMov(t.xy2d, feNeg(t.xy2d), negative),
		};
	}
} else {
	export {
		Fe,
		feZero,
		feOne,
		feFromBytes,
		feToBytes,
		feAdd,
		feSub,
		feAddLoose,
		feSubLoose,
		feNeg,
		feMul,
		feMul121666,
		feSqr,
		fePow2252m3,
		feInv,
		feIsZero,
		feEqual,
		feIsNegative,
		feCMov,
		Niels,
		feSelectNiels,
	} from "./fe25519";
}
