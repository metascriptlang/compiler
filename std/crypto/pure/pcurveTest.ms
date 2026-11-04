import {
	Limbs, Modulus, mul, add, sub, opp, invert, equal, fromBytes, toBytes,
	toMontgomery, fromMontgomery,
} from "./montgomery";
import {
	CurveMath, Point, basePoint, dbl, addPoints, neg, mulSecret, mulBase, mulDoubleBasePublic,
	encodePoint, sqrt, isSquare, p256Math, p384Math,
} from "./pcurve";
import { encodeHex } from "../../core/encoding";

// Expected values: Python integers on the SEC 2 constants (a and b below are
// the repeated 0123456789abcdef and fedcba9876543210 words).

function plain(md: Readonly<Modulus>, hex: string): Limbs {
	const limbs = fromBytes(md, hex.decodeHex(), 0);
	if (limbs == null) throw new Error(`not below the modulus: ${hex}`);
	return limbs;
}

function mont(md: Readonly<Modulus>, hex: string): Limbs {
	return toMontgomery(md, plain(md, hex));
}

function hexOf(md: Readonly<Modulus>, a: Limbs): string {
	return encodeHex(toBytes(md, fromMontgomery(md, a)));
}

function pointHex(cm: Readonly<CurveMath>, p: Point): string {
	const bytes = encodePoint(cm, p);
	return bytes == null ? "identity" : encodeHex(bytes as uint8[]);
}

const a256 = "0123456789abcdef".repeat(4);
const b256 = "fedcba9876543210".repeat(4);
const a384 = "0123456789abcdef".repeat(6);
const b384 = "fedcba9876543210".repeat(6);

test "field and scalar products, sums and differences match known values" {
	const fp = p256Math.field;
	const fn = p256Math.order;
	assert hexOf(fp, mul(fp, mont(fp, a256), mont(fp, b256))) == "75e0fb4dfbe38a54f2f1809043cd2b48a801bd52c02492164d2810a05c7a8411";
	assert hexOf(fn, mul(fn, mont(fn, a256), mont(fn, b256))) == "8533a1d491863c17e969adb91a2e056e9cbee1672e03cce3bf9bbd9f3d39f048";
	assert hexOf(fp, add(fp, mont(fp, a256), mont(fp, b256))) == "00000000fffffffeffffffffffffffffffffffff000000000000000000000000";
	assert hexOf(fp, sub(fp, mont(fp, a256), mont(fp, b256))) == "02468ace13579bdf02468acf13579bde02468ad013579bde02468acf13579bde";
	assert hexOf(fp, sub(fp, mont(fp, b256), mont(fp, a256))) == "fdb97530eca86421fdb97530eca86421fdb97530eca86421fdb97530eca86421";
	const gp = p384Math.field;
	const gn = p384Math.order;
	assert hexOf(gp, mul(gp, mont(gp, a384), mont(gp, b384))) == "aec1f2b7679bcb63d21ac547fa752f95f69591d93d0a5f0b9958df7f54a2afd11d208a579be16fc8b6a6b8f5d4c26731";
	assert hexOf(gn, mul(gn, mont(gn, a384), mont(gn, b384))) == "0df01bc78fb415533a6da720d04fc378d84a2c8c314dd2c0750759d904b1e99ae953dc7f612cb7241024edc65c4cdd71";
	assert hexOf(gp, add(gp, mont(gp, a384), mont(gp, b384))) == "000000000000000000000000000000000000000000000000000000000000000100000000ffffffffffffffff00000000";
	assert hexOf(gp, sub(gp, mont(gp, a384), mont(gp, b384))) == "02468acf13579bde02468acf13579bde02468acf13579bde02468acf13579bdd02468ace13579bde02468ad013579bde";
}

test "the inverse multiplies back to one in both fields and both scalar rings" {
	for (const md of [p256Math.field, p256Math.order]) {
		const x = mont(md, a256);
		assert equal(md, mul(md, x, invert(md, x)), md.one);
	}
	for (const md of [p384Math.field, p384Math.order]) {
		const x = mont(md, a384);
		assert equal(md, mul(md, x, invert(md, x)), md.one);
	}
	assert hexOf(p256Math.field, invert(p256Math.field, mont(p256Math.field, a256))) == "de81eb370af1f92cc7b6d08f0a124a1ec6de1a033b9b93de117b5254f0490691";
	assert hexOf(p256Math.order, invert(p256Math.order, mont(p256Math.order, a256))) == "1359162ede91207ccaea1de94afc63c1db5a967c1e6e21f91ef9f077f20a46b6";
	assert hexOf(p384Math.field, invert(p384Math.field, mont(p384Math.field, a384))) == "083ba7221f8540bce4baa0d81a28cd3a9cd5fda67bd6eacf37bcee804c2e7a83953328d6fdb7499c7a3679d32aec85a7";
	assert hexOf(p384Math.order, invert(p384Math.order, mont(p384Math.order, a384))) == "46ae825365df7a1d62825d81fa487fc38308db2cd6f56ceb22e631917f150eb006e8baeef59facc741d22ac15aad230b";
}

test "the Montgomery form round-trips, a value not below the modulus is refused, and the m' constants invert the low limb" {
	const fp = p256Math.field;
	assert encodeHex(toBytes(fp, fromMontgomery(fp, mont(fp, a256)))) == a256;
	assert encodeHex(toBytes(p384Math.order, fromMontgomery(p384Math.order, mont(p384Math.order, b384)))) == b384;
	assert fromBytes(fp, toBytes(fp, fp.m), 0) == null;
	assert fromBytes(p384Math.order, toBytes(p384Math.order, p384Math.order.m), 0) == null;
	for (const md of [p256Math.field, p256Math.order, p384Math.field, p384Math.order]) {
		assert md.m[0] * md.mPrime + 1 == 0;
	}
}

test "a square has a root whose square is it, and minus a square has none" {
	for (const cm of [p256Math, p384Math]) {
		const f = cm.field;
		const x = mont(f, cm.field.words == 8 ? a256 : a384);
		const xx = mul(f, x, x);
		const root = sqrt(cm, xx);
		assert root != null;
		assert equal(f, mul(f, root as Limbs, root as Limbs), xx);
		assert isSquare(cm, xx);
		assert sqrt(cm, opp(f, xx)) == null;
		assert !isSquare(cm, opp(f, xx));
	}
}

test "2G matches the known point by doubling, by complete addition and by scalar multiplication" {
	const two256 = "02".padStart(64, "0").decodeHex();
	const g256 = basePoint(p256Math);
	const want256 = "047cf27b188d034f7e8a52380304b51ac3c08969e277f21b35a60b48fc4766997807775510db8ed040293d9ac69f7430dbba7dade63ce982299e04b79d227873d1";
	assert pointHex(p256Math, dbl(p256Math, g256)) == want256;
	assert pointHex(p256Math, addPoints(p256Math, g256, g256)) == want256;
	assert pointHex(p256Math, mulSecret(p256Math, g256, two256) as Point) == want256;
	const two384 = "02".padStart(96, "0").decodeHex();
	const g384 = basePoint(p384Math);
	const want384 = "0408d999057ba3d2d969260045c55b97f089025959a6f434d651d207d19fb96e9e4fe0e86ebe0e64f85b96a9c75295df618e80f1fa5b1b3cedb7bfe8dffd6dba74b275d875bc6cc43e904e505f256ab4255ffd43e94d39e22d61501e700a940e80";
	assert pointHex(p384Math, dbl(p384Math, g384)) == want384;
	assert pointHex(p384Math, mulSecret(p384Math, g384, two384) as Point) == want384;
	assert pointHex(p256Math, mulBase(p256Math, two256) as Point) == want256;
	assert pointHex(p384Math, mulBase(p384Math, two384) as Point) == want384;
}

test "the generator times the group order is the identity, and times n - 1 is minus the generator" {
	for (const cm of [p256Math, p384Math]) {
		const n = toBytes(cm.order, cm.order.m);
		const g = basePoint(cm);
		assert mulSecret(cm, g, n) == null;
		assert mulBase(cm, n) == null;
		const nMinusOne = n.slice(0);
		nMinusOne[n.length - 1] = (nMinusOne[n.length - 1] - 1) as uint8;
		const minusG = mulSecret(cm, g, nMinusOne);
		assert minusG != null;
		assert pointHex(cm, minusG as Point) == pointHex(cm, neg(cm, g));
		const one = new Array<uint8>(n.length);
		one[n.length - 1] = 1;
		assert mulDoubleBasePublic(cm, nMinusOne, g, one) == null;
		assert pointHex(cm, mulDoubleBasePublic(cm, one, g, one) as Point) == pointHex(cm, dbl(cm, g));
	}
}

function samePoint(cm: Readonly<CurveMath>, p: Point, q: Point): boolean {
	const f = cm.field;
	return equal(f, mul(f, p.x, q.z), mul(f, q.x, p.z)) && equal(f, mul(f, p.y, q.z), mul(f, q.y, p.z));
}

test "every entry of the native base table is j·16^i·G: the scalar j·16^i reads entry j of window i, and 8·16^i reads -8 and then window i + 1" {
	when (c) {
		for (const cm of [p256Math, p384Math]) {
			const size = 4 * cm.field.words;
			let base = basePoint(cm);
			for (let i = 0; i < 2 * size; i++) {
				let want = base;
				for (let j = 1; j <= 8; j++) {
					const k = new Array<uint8>(size);
					k[size - 1 - (i >> 1)] = (j << (4 * (i & 1))) as uint8;
					const got = mulBase(cm, k);
					assert got != null;
					assert samePoint(cm, got as Point, want);
					want = addPoints(cm, want, base);
				}
				base = dbl(cm, dbl(cm, dbl(cm, dbl(cm, base))));
			}
		}
	}
}
