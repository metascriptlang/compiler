import { encodeHex, decodeHex } from "../../core/encoding";
import {
	Fe,
	feFromBytes,
	feToBytes,
	feAdd,
	feSub,
	feMul,
	feSqr,
	feInv,
	fePow2252m3,
	feIsZero,
	feNeg,
} from "./fe25519";
import {
	scalarReduce32,
	scalarReduce64,
	scalarMulAdd,
	scalarIsCanonical,
} from "./scalar25519";

// Expected values computed with Python integers, little-endian hex.
const fa = "6aad39f4c2aaed1a8a27e534ce4aa7426078fe43c27a88b4ada9dd74482b8410";
const fb = "232cae48c88fff9b500f0b4cca8e9f33a72971aa44125c7294d11bb5c82df818";
const orderHex =
	"edd3f55c1a631258d69cf7a2def9de1400000000000000000000000000000010";

function fe(hex: string): Fe {
	return feFromBytes(hex.decodeHex(), 0);
}

test "field products, sum, difference and square match known values" {
	assert feToBytes(feMul(fe(fa), fe(fb))).encodeHex() ==
		"4d9c89b13b70b95cd657e3834059cf68e24ce21919e03c3a40f70b9a3d6bf258";
	assert feToBytes(feSqr(fe(fa))).encodeHex() ==
		"4318b58bddddf6e546fba0f956a2e5540edf5573dcd505c51222524f1ca28c44";
	assert feToBytes(feAdd(fe(fa), fe(fb))).encodeHex() ==
		"8dd9e73c8b3aedb6da36f08098d9467607a26fee068de426427bf92911597c29";
	assert feToBytes(feSub(fe(fa), fe(fb))).encodeHex() ==
		"34818babfa1aee7e3918dae803bc070fb94e8d997d682c4219d8c1bf7ffd8b77";
}

test "the field inverse matches and multiplies back to one" {
	assert feToBytes(feInv(fe(fa))).encodeHex() ==
		"3eb7b9b06dbd9f24df520e8f63ba87954dd94f0fa3a043496e36afc2a4d8b36e";
	assert feToBytes(feMul(fe(fa), feInv(fe(fa)))).encodeHex() ==
		"0100000000000000000000000000000000000000000000000000000000000000";
	assert feIsZero(feInv(fe("00".repeat(32))));
}

test "the square-root exponent matches, and x^2 has root x" {
	assert feToBytes(fePow2252m3(fe(fa))).encodeHex() ==
		"8fc94131dd1cd8226401b5f403742373df48b2a8f126e3de8e30fa77d601c34b";
	// r = u^((P + 3) / 8) squares to u or -u when u is a square.
	const u = feSqr(fe(fa));
	const r = feMul(fePow2252m3(u), u);
	const rr = feSqr(r);
	assert feIsZero(feSub(rr, u)) || feIsZero(feAdd(rr, u));
}

test "a value at or above P reduces, and bit 255 is ignored" {
	const max = fe(
		"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
	);
	assert feToBytes(feAdd(max, max)).encodeHex() ==
		"2400000000000000000000000000000000000000000000000000000000000000";
	const p = fe(
		"edffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
	);
	assert feIsZero(p);
	assert feIsZero(
		fe("edffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"),
	);
	assert feToBytes(feNeg(fe("01" + "00".repeat(31)))).encodeHex() ==
		"ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f";
}

test "reduce64 of 2^512 - 1 and of a random value" {
	assert scalarReduce64("ff".repeat(64).decodeHex()).encodeHex() ==
		"000f9c44e31106a447938568a71b0ed065bef517d273ecce3d9a307c1b419903";
	assert scalarReduce64(
		"52c00060c28921553a62c526134241b82b54e7a6e2d5c69174e5e75e541056dcd99a08e47ccc61a0c7fd186f5fc43b369986715a5578f834b4324705eb25294a".decodeHex(),
	).encodeHex() ==
		"be4ec057ca675cd3d2ba90c55772aae0026665ccf59e121a418acf844c23fd0a";
	assert scalarReduce64("00".repeat(64).decodeHex()).encodeHex() ==
		"00".repeat(32);
	assert scalarReduce64((orderHex + "00".repeat(32)).decodeHex()).encodeHex() ==
		"00".repeat(32);
}

test "reduce32 and mulAdd match known values" {
	assert scalarReduce32(
		"0102016c9e45bf9fcd7bc5036e3c2e972bed6264cf29988e597852748da15a56".decodeHex(),
	).encodeHex() ==
		"60de339b1a5663e79d6befd4145bd32e2bed6264cf29988e597852748da15a06";
	assert scalarReduce32(orderHex.decodeHex()).encodeHex() == "00".repeat(32);
	const a =
		"57ac9570ee671978bc641eb94c0e31eb21eb4ef5d7853da56a0ecc50cfd63090".decodeHex();
	const b =
		"52d68e7732bc13156cefd33dc459bff2be5653a3566c3d4fa23ab942ecedc086".decodeHex();
	const c =
		"78408cf78b253434bee6f24cf56c3e9a471ec54a6fc4e51e90817f96c0f8e394".decodeHex();
	assert scalarMulAdd(a, b, c).encodeHex() ==
		"ea5cf4390046136114b832d066d98b5e01dbf6ea14abb2d62bb5bfbdad480b0f";
}

test "a scalar at or above L is not canonical" {
	assert !scalarIsCanonical(orderHex.decodeHex(), 0);
	assert scalarIsCanonical(
		"ecd3f55c1a631258d69cf7a2def9de1400000000000000000000000000000010".decodeHex(),
		0,
	);
	assert !scalarIsCanonical("ff".repeat(32).decodeHex(), 0);
	assert scalarIsCanonical("00".repeat(32).decodeHex(), 0);
	assert !scalarIsCanonical(
		"eed3f55c1a631258d69cf7a2def9de1400000000000000000000000000000010".decodeHex(),
		0,
	);
}
