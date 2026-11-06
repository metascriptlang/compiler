// Differential check of the pure EC surface against std/crypto/ec, which on the native backend is
// mbedTLS through PSA: keys cross through PEM both ways, each side verifies the other's signatures
// and refuses them on a changed message, and both derive the same ECDH secret.

import {
	EcCurve, EcPrivateKey, EcPublicKey, ecdsaSignSync, ecdsaVerifySync, ecdhSync,
} from "./ecNative";
import {
	EcPrivateKey as VendorPrivateKey, EcPublicKey as VendorPublicKey,
	ecdsaSignSync as vendorSign, ecdsaVerifySync as vendorVerify, ecdhSync as vendorEcdh,
} from "../oracle/ec";
import { encodeHex } from "../../core/encoding";

function must<T, E>(result: Result<T, E>): T {
	if (!result.ok) throw new Error("differential setup failed");
	return result.value;
}

function expect(ok: boolean, what: string): void {
	if (!ok) throw new Error(`differential mismatch: ${what}`);
}

class Seeded {
	state: uint32 = 0x9e3779b9;

	next(): uint32 {
		let x = this.state;
		x ^= x << 13;
		x ^= x >> 17;
		x ^= x << 5;
		this.state = x;
		return x;
	}

	bytes(length: int32): uint8[] {
		const out = new Array<uint8>(length);
		for (let i = 0; i < length; i++) out[i] = this.next() as uint8;
		return out;
	}
}

const edgeLengths: int32[] = [
	0, 1, 31, 32, 33, 47, 48, 49, 55, 56, 63, 64, 65, 111, 112, 127, 128, 129,
	255, 256, 1023, 1024, 2047, 2048,
];
const hashes: string[] = ["sha256", "sha384", "sha512"];

function lengths(random: Seeded): int32[] {
	const out = edgeLengths.slice(0);
	for (let i = 0; i < 8; i++) out.push((random.next() % 2049) as int32);
	return out;
}

function changed(message: Readonly<uint8[]>): uint8[] {
	const out = message.slice(0);
	if (out.length == 0) {
		out.push(1);
	} else {
		out[out.length >> 1] = (out[out.length >> 1] ^ 0x40) as uint8;
	}
	return out;
}

/** Signatures both ways over many lengths and the three hashes; returns the checks run. */
function crossSign(curve: EcCurve, random: Seeded): int32 {
	const pure = must(EcPrivateKey.generateSync(curve));
	const vendor = must(VendorPrivateKey.generateSync(curve));
	const vendorAsPure = must(EcPrivateKey.importPemSync(must(vendor.exportPemSync())));
	const pureAsVendor = must(VendorPrivateKey.importPemSync(must(pure.exportPemSync())));
	const purePublic = pure.publicKey();
	const vendorPublic = vendor.publicKey();
	expect(must(vendorAsPure.publicKey().exportPemSync()) == must(vendorPublic.exportPemSync()), `${curve} vendor key through pure PEM`);
	expect(must(pureAsVendor.publicKey().exportPemSync()) == must(purePublic.exportPemSync()), `${curve} pure key through vendor PEM`);
	const pureOfVendor = vendorAsPure.publicKey();
	const vendorOfPure = pureAsVendor.publicKey();
	let checks = 0;
	let index = 0;
	for (const length of lengths(random)) {
		const hash = hashes[index % 3];
		index++;
		const message = random.bytes(length);
		const other = changed(message);
		const ours = must(ecdsaSignSync(pure, message, hash));
		const theirs = must(vendorSign(vendor, message, hash));
		expect(vendorVerify(vendorOfPure, message, ours, hash), `${curve} ${hash} ${length} B: vendor verifies pure`);
		expect(!vendorVerify(vendorOfPure, other, ours, hash), `${curve} ${hash} ${length} B: vendor refuses pure on a changed message`);
		expect(ecdsaVerifySync(pureOfVendor, message, theirs, hash), `${curve} ${hash} ${length} B: pure verifies vendor`);
		expect(!ecdsaVerifySync(pureOfVendor, other, theirs, hash), `${curve} ${hash} ${length} B: pure refuses vendor on a changed message`);
		expect(ecdsaVerifySync(purePublic, message, ours, hash), `${curve} ${hash} ${length} B: pure verifies pure`);
		checks += 5;
	}
	return checks;
}

/** Shared secrets of pure and vendor keys agree in every pairing. */
function crossAgree(curve: EcCurve, rounds: int32): int32 {
	for (let i = 0; i < rounds; i++) {
		const pure = must(EcPrivateKey.generateSync(curve));
		const vendor = must(VendorPrivateKey.generateSync(curve));
		const pureOfVendor = must(EcPublicKey.importPemSync(must(vendor.publicKey().exportPemSync())));
		const vendorOfPure = must(VendorPublicKey.importPemSync(must(pure.publicKey().exportPemSync())));
		const ours = encodeHex(must(ecdhSync(pure, pureOfVendor)));
		const theirs = encodeHex(must(vendorEcdh(vendor, vendorOfPure)));
		expect(ours == theirs, `${curve} ECDH secret`);
	}
	return rounds;
}

test "pure ECDSA and ECDH agree with std/crypto/ec on P-256 and P-384" {
	const random = new Seeded();
	const curves: EcCurve[] = ["p256", "p384"];
	let checks = 0;
	for (const curve of curves) {
		checks += crossSign(curve, random);
		checks += crossAgree(curve, 8);
	}
	console.log(`ec differential: ${checks} checks`);
}
