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
		feSqr,
		fePow2252m3,
		feInv,
		feIsZero,
		feEqual,
		feIsNegative,
		feCMov,
	} from "./fe25519";
}
