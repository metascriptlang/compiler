// GCM-128 vectors: McGrew & Viega, "The Galois/Counter Mode of Operation (GCM)", 2004, Appendix B
// (basis for NIST SP 800-38D). US government work; no licence restriction.
// GCM-256 vectors: Zig stdlib lib/std/crypto/aes_gcm.zig, commit 16d31ceed5de91b469e010b4a8d515236ad6bf14
// (MIT, Copyright (c) Zig contributors). Values are purely mathematical.
// GCM-192 and GCM-256 TC7-TC8, TC13-TC16: the same McGrew & Viega appendix.
// Block vectors: FIPS-197 Appendix C.1-C.3. US gov work.
// CBC vectors: NIST SP 800-38A (2001), Appendix F.2.1, F.2.3 and F.2.5 (AES-128/192/256-CBC). US gov work.
// NOT constant-time: T-table AES leaks the key via cache timing. Phase 2 audit parked.

import { expandKey, expandKeyDecrypt, gcmSealWithNonce, gcmOpen, gcmEncryptInto, gcmSealAt, gcmDecryptInto, cbcEncrypt, cbcDecrypt } from "./aes";
import { newGhash, updateGhash, finishGhash } from "./ghash";
import { encodeHex, decodeHex } from "../../core/encoding";

function eqHex(got: Readonly<Span<uint8>>, want: string): boolean {
	return got.encodeHex() == want;
}

const k128z    = "00000000000000000000000000000000";
const k128f    = "feffe9928665731c6d6a8f9467308308";
const k256zig  = "6969696969696969696969696969696969696969696969696969696969696969";
const ivZ      = "000000000000000000000000";
const ivCafe   = "cafebabefacedbaddecaf888";
const ivZig    = "424242424242424242424242";
const aadF     = "feedfacedeadbeeffeedfacedeadbeefabaddad2";
const aadZig   = "546573742077697468206173736f6369617465642064617461";

test "GCM-128 TC1 empty plaintext empty AAD" {
	const xk     = expandKey(k128z.decodeHex());
	const sealed = gcmSealWithNonce(xk, ivZ.decodeHex(), "".decodeHex(), "".decodeHex());
	assert sealed.length == 28;
	assert eqHex(sealed, "00000000000000000000000058e2fccefa7e3061367f1d57a4e7455a");
	const pt = gcmOpen(xk, sealed, "".decodeHex());
	assert pt != null;
	if (pt != null) assert pt.length == 0;
}

test "GCM-128 TC2 one full block empty AAD" {
	const xk     = expandKey(k128z.decodeHex());
	const sealed = gcmSealWithNonce(xk, ivZ.decodeHex(), "00000000000000000000000000000000".decodeHex(), "".decodeHex());
	assert sealed.length == 44;
	assert eqHex(sealed.slice(12, 28), "0388dace60b6a392f328c2b971b2fe78");
	assert eqHex(sealed.slice(28, 44), "ab6e47d42cec13bdf53a67b21257bddf");
	const pt = gcmOpen(xk, sealed, "".decodeHex());
	assert pt != null;
	if (pt != null) assert eqHex(pt, "00000000000000000000000000000000");
}

test "GCM-128 TC3 four full blocks empty AAD" {
	const pt128 = "d9313225f88406e5a55909c5aff5269a86a7a9531534f7da2e4c303d8a318a721c3c0c95956809532fcf0e2449a6b525b16aedf5aa0de657ba637b391aafd255";
	const ct128 = "42831ec2217774244b7221b784d0d49ce3aa212f2c02a4e035c17e2329aca12e21d514b25466931c7d8f6a5aac84aa051ba30b396a0aac973d58e091473f5985";
	const xk     = expandKey(k128f.decodeHex());
	const sealed = gcmSealWithNonce(xk, ivCafe.decodeHex(), pt128.decodeHex(), "".decodeHex());
	assert sealed.length == 92;
	assert eqHex(sealed.slice(12, 76), ct128);
	assert eqHex(sealed.slice(76, 92), "4d5c2af327cd64a62cf35abd2ba6fab4");
	const back = gcmOpen(xk, sealed, "".decodeHex());
	assert back != null;
	if (back != null) assert eqHex(back, pt128);
}

test "GCM-128 TC4 60-byte partial block with AAD" {
	const pt60 = "d9313225f88406e5a55909c5aff5269a86a7a9531534f7da2e4c303d8a318a721c3c0c95956809532fcf0e2449a6b525b16aedf5aa0de657ba637b39";
	const ct60 = "42831ec2217774244b7221b784d0d49ce3aa212f2c02a4e035c17e2329aca12e21d514b25466931c7d8f6a5aac84aa051ba30b396a0aac973d58e091";
	const xk     = expandKey(k128f.decodeHex());
	const sealed = gcmSealWithNonce(xk, ivCafe.decodeHex(), pt60.decodeHex(), aadF.decodeHex());
	assert sealed.length == 88;
	assert eqHex(sealed.slice(12, 72), ct60);
	assert eqHex(sealed.slice(72, 88), "5bc94fbc3221a5db94fae95ae7121a47");
	const back = gcmOpen(xk, sealed, aadF.decodeHex());
	assert back != null;
	if (back != null) assert eqHex(back, pt60);
}

test "GCM-256 empty plaintext empty AAD" {
	const xk     = expandKey(k256zig.decodeHex());
	const sealed = gcmSealWithNonce(xk, ivZig.decodeHex(), "".decodeHex(), "".decodeHex());
	assert sealed.length == 28;
	assert eqHex(sealed.slice(12, 28), "6b6ff610a16fa4cd59f1fb7903154e92");
	const pt = gcmOpen(xk, sealed, "".decodeHex());
	assert pt != null;
	if (pt != null) assert pt.length == 0;
}

test "GCM-256 empty plaintext with AAD" {
	const xk     = expandKey(k256zig.decodeHex());
	const sealed = gcmSealWithNonce(xk, ivZig.decodeHex(), "".decodeHex(), aadZig.decodeHex());
	assert sealed.length == 28;
	assert eqHex(sealed.slice(12, 28), "262ed164c2dfb26e080a9d108dd9dd4c");
}

test "GCM-256 partial block 22 bytes empty AAD" {
	const pt22   = "546573742077697468206d657373616765206f6e6c79";
	const xk     = expandKey(k256zig.decodeHex());
	const sealed = gcmSealWithNonce(xk, ivZig.decodeHex(), pt22.decodeHex(), "".decodeHex());
	assert sealed.length == 50;
	assert eqHex(sealed.slice(12, 34), "5ca1642d90009fea33d01f78cf6eefaf01d539472f7c");
	assert eqHex(sealed.slice(34, 50), "07cd7fc9103e2f9e9bf2dfaa319caff4");
	const back = gcmOpen(xk, sealed, "".decodeHex());
	assert back != null;
	if (back != null) assert eqHex(back, pt22);
}

test "GCM-256 partial block 17 bytes with AAD" {
	const pt17   = "546573742077697468206d657373616765";
	const xk     = expandKey(k256zig.decodeHex());
	const sealed = gcmSealWithNonce(xk, ivZig.decodeHex(), pt17.decodeHex(), aadZig.decodeHex());
	assert sealed.length == 45;
	assert eqHex(sealed.slice(12, 29), "5ca1642d90009fea33d01f78cf6eefaf01");
	assert eqHex(sealed.slice(29, 45), "64accec679d444e2373bd9f6796c0d2c");
	const back = gcmOpen(xk, sealed, aadZig.decodeHex());
	assert back != null;
	if (back != null) assert eqHex(back, pt17);
}

test "GCM wrong tag is rejected" {
	const xk     = expandKey(k128z.decodeHex());
	const sealed = gcmSealWithNonce(xk, ivZ.decodeHex(), "".decodeHex(), "".decodeHex());
	assert gcmOpen(xk, sealed, "".decodeHex()) != null;
	const tampered = sealed.slice(0);
	tampered[27] = (tampered[27] ^ 1) as uint8;
	assert gcmOpen(xk, tampered, "".decodeHex()) == null;
}

test "GCM wrong AAD is rejected" {
	const xk     = expandKey(k128z.decodeHex());
	const sealed = gcmSealWithNonce(xk, ivZ.decodeHex(), "00".decodeHex(), "".decodeHex());
	assert gcmOpen(xk, sealed, "".decodeHex()) != null;
	assert gcmOpen(xk, sealed, "aa".decodeHex()) == null;
}

test "GCM tampered ciphertext is rejected" {
	const xk     = expandKey(k128z.decodeHex());
	const sealed = gcmSealWithNonce(xk, ivZ.decodeHex(), "00000000000000000000000000000000".decodeHex(), "".decodeHex());
	assert gcmOpen(xk, sealed, "".decodeHex()) != null;
	const tampered = sealed.slice(0);
	tampered[12] = (tampered[12] ^ 0xff) as uint8;
	assert gcmOpen(xk, tampered, "".decodeHex()) == null;
}

const cbcKey128 = "2b7e151628aed2a6abf7158809cf4f3c";
const cbcKey256 = "603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4";
const cbcIv     = "000102030405060708090a0b0c0d0e0f";
const cbcP4     = "6bc1bee22e409f96e93d7e117393172aae2d8a571e03ac9c9eb76fac45af8e5130c81c46a35ce411e5fbc1191a0a52eff69f2445df4f9b17ad2b417be66c3710";
const cbcC4_128 = "7649abac8119b246cee98e9b12e9197d5086cb9b507219ee95db113a917678b273bed6b8e3c1743b7116e69e222295163ff1caa1681fac09120eca307586e1a7";
const cbcC4_256 = "f58c4c04d6e5f1ba779eabfb5f7bfbd69cfc4e967edb808d679f777bc6702c7d39f23369a9d9bacfa530e26304231461b2eb05e2c39be9fcda6c19078c6a9d1b";

test "CBC-128 SP 800-38A F.2.1 four-block ciphertext matches standard" {
	const out = cbcEncrypt(expandKey(cbcKey128.decodeHex()), cbcIv.decodeHex(), cbcP4.decodeHex());
	assert out.length == 80;
	assert eqHex(out.slice(0, 64), cbcC4_128);
}

test "CBC-256 SP 800-38A F.2.5 four-block ciphertext matches standard" {
	const out = cbcEncrypt(expandKey(cbcKey256.decodeHex()), cbcIv.decodeHex(), cbcP4.decodeHex());
	assert out.length == 80;
	assert eqHex(out.slice(0, 64), cbcC4_256);
}

test "CBC-128 round-trip aligned and partial-block inputs" {
	const xk  = expandKey(cbcKey128.decodeHex());
	const xkD = expandKeyDecrypt(cbcKey128.decodeHex());
	const iv  = cbcIv.decodeHex();
	for (const ptHex of ["", "aabbccdd", cbcP4]) {
		const cipher = cbcEncrypt(xk, iv, ptHex.decodeHex());
		const plain  = cbcDecrypt(xkD, iv, cipher);
		assert plain != null;
		if (plain != null) assert eqHex(plain, ptHex);
	}
}

test "CBC-128 bad padding and wrong size return null" {
	const xkD = expandKeyDecrypt(cbcKey128.decodeHex());
	const iv  = cbcIv.decodeHex();
	assert cbcDecrypt(xkD, iv, "".decodeHex()) == null;
	assert cbcDecrypt(xkD, iv, "aabbcc".decodeHex()) == null;
	// SP 800-38A F.2.1 C1 decrypts to P1; P1[15] = 0x2a = 42 > 16, so PKCS7 fails.
	assert cbcDecrypt(xkD, iv, "7649abac8119b246cee98e9b12e9197d".decodeHex()) == null;
}

const fipsPlain = "00112233445566778899aabbccddeeff";
const zeroIv16 = "00000000000000000000000000000000";

// CBC under a zero IV makes its first block the bare cipher, so FIPS-197 checks the block in both directions.
function fipsBlock(keyHex: string, want: string): boolean {
	const cipher = cbcEncrypt(expandKey(keyHex.decodeHex()), zeroIv16.decodeHex(), fipsPlain.decodeHex());
	if (cipher.length != 32 || !eqHex(cipher.slice(0, 16), want)) return false;
	const plain = cbcDecrypt(expandKeyDecrypt(keyHex.decodeHex()), zeroIv16.decodeHex(), cipher);
	return plain != null && eqHex(plain, fipsPlain);
}

test "FIPS-197 C.1 AES-128 block" {
	assert fipsBlock("000102030405060708090a0b0c0d0e0f", "69c4e0d86a7b0430d8cdb78070b4c55a");
}

test "FIPS-197 C.2 AES-192 block" {
	assert fipsBlock("000102030405060708090a0b0c0d0e0f1011121314151617", "dda97ca4864cdfe06eaf70a0ec0d7191");
}

test "FIPS-197 C.3 AES-256 block" {
	assert fipsBlock("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f", "8ea2b7ca516745bfeafc49904b496089");
}

test "CBC-192 SP 800-38A F.2.3 four-block ciphertext and round trip" {
	const key = "8e73b0f7da0e6452c810f32b809079e562f8ead2522c6b7b";
	const out = cbcEncrypt(expandKey(key.decodeHex()), cbcIv.decodeHex(), cbcP4.decodeHex());
	assert out.length == 80;
	assert eqHex(out, "4f021db243bc633d7178183a9fa071e8b4d9ada9ad7dedf4e5e738763f69145a571b242012fb7ae07fa9baac3df102e008b0e27988598881d920a9e64f5615cd612ccd79224b350935d45dd6a98f8176");
	const back = cbcDecrypt(expandKeyDecrypt(key.decodeHex()), cbcIv.decodeHex(), out);
	assert back != null;
	if (back != null) assert eqHex(back, cbcP4);
}

test "CBC-256 round trip at every length up to two blocks" {
	const xk  = expandKey(cbcKey256.decodeHex());
	const xkD = expandKeyDecrypt(cbcKey256.decodeHex());
	const iv  = cbcIv.decodeHex();
	const all = cbcP4.decodeHex();
	for (let n = 0; n <= 32; n++) {
		const plain = all.slice(0, n);
		const cipher = cbcEncrypt(xk, iv, plain);
		assert cipher.length == (n / 16) * 16 + 16;
		const back = cbcDecrypt(xkD, iv, cipher);
		assert back != null;
		if (back != null) assert eqHex(back, plain.encodeHex());
	}
}

test "CBC round trip across every pass size of each key size" {
	const iv = cbcIv.decodeHex();
	for (const keyHex of [cbcKey128, k128f + "0001020304050607", cbcKey256]) {
		const xk  = expandKey(keyHex.decodeHex());
		const xkD = expandKeyDecrypt(keyHex.decodeHex());
		for (let blocks = 1; blocks <= 40; blocks++) {
			const plain = new Array<uint8>(blocks * 16 - 1);
			for (let i = 0; i < plain.length; i++) plain[i] = ((i * 7 + blocks) & 0xff) as uint8;
			const back = cbcDecrypt(xkD, iv, cbcEncrypt(xk, iv, plain));
			assert back != null;
			if (back != null) assert eqHex(back, plain.encodeHex());
		}
	}
}

test "CBC tampered last block fails padding" {
	const xk  = expandKey(cbcKey128.decodeHex());
	const xkD = expandKeyDecrypt(cbcKey128.decodeHex());
	const iv  = cbcIv.decodeHex();
	const cipher = cbcEncrypt(xk, iv, "aabbccdd".decodeHex());
	assert cipher.length == 16;
	// The IV's last byte flips the plain text's last pad byte from 0x0c to 0x0d.
	const badIv = iv.slice(0);
	badIv[15] = (badIv[15] ^ 1) as uint8;
	assert cbcDecrypt(xkD, badIv, cipher) == null;
}

test "GCM-192 TC7 and TC8" {
	const xk = expandKey("000000000000000000000000000000000000000000000000".decodeHex());
	const empty = gcmSealWithNonce(xk, ivZ.decodeHex(), "".decodeHex(), "".decodeHex());
	assert eqHex(empty.slice(12, 28), "cd33b28ac773f74ba00ed1f312572435");
	const one = gcmSealWithNonce(xk, ivZ.decodeHex(), k128z.decodeHex(), "".decodeHex());
	assert eqHex(one.slice(12, 28), "98e7247c07f0fe411c267e4384b0f600");
	assert eqHex(one.slice(28, 44), "2ff58d80033927ab8ef4d4587514f0fb");
	const back = gcmOpen(xk, one, "".decodeHex());
	assert back != null;
	if (back != null) assert eqHex(back, k128z);
}

test "GCM-256 TC13 and TC14" {
	const xk = expandKey("0000000000000000000000000000000000000000000000000000000000000000".decodeHex());
	const empty = gcmSealWithNonce(xk, ivZ.decodeHex(), "".decodeHex(), "".decodeHex());
	assert eqHex(empty.slice(12, 28), "530f8afbc74536b9a963b4f1c4cb738b");
	const one = gcmSealWithNonce(xk, ivZ.decodeHex(), k128z.decodeHex(), "".decodeHex());
	assert eqHex(one.slice(12, 28), "cea7403d4d606b6e074ec5d3baf39d18");
	assert eqHex(one.slice(28, 44), "d0d1c8a799996bf0265b98b5d48ab919");
}

test "GCM-256 TC15 and TC16" {
	const pt = "d9313225f88406e5a55909c5aff5269a86a7a9531534f7da2e4c303d8a318a721c3c0c95956809532fcf0e2449a6b525b16aedf5aa0de657ba637b391aafd255";
	const ct = "522dc1f099567d07f47f37a32a84427d643a8cdcbfe5c0c97598a2bd2555d1aa8cb08e48590dbb3da7b08b1056828838c5f61e6393ba7a0abcc9f662898015ad";
	const xk = expandKey((k128f + k128f).decodeHex());
	const full = gcmSealWithNonce(xk, ivCafe.decodeHex(), pt.decodeHex(), "".decodeHex());
	assert eqHex(full.slice(12, 76), ct);
	assert eqHex(full.slice(76, 92), "b094dac5d93471bdec1a502270e3cc6c");
	const part = gcmSealWithNonce(xk, ivCafe.decodeHex(), pt.slice(0, 120).decodeHex(), aadF.decodeHex());
	assert eqHex(part.slice(12, 72), ct.slice(0, 120));
	assert eqHex(part.slice(72, 88), "76fc6ece0f4e1768cddf8853bb2d551b");
	const back = gcmOpen(xk, part, aadF.decodeHex());
	assert back != null;
	if (back != null) assert eqHex(back, pt.slice(0, 120));
	assert gcmOpen(xk, part, "".decodeHex()) == null;
}

test "GCM open refuses a blob shorter than nonce and tag" {
	const xk = expandKey(k128z.decodeHex());
	assert gcmOpen(xk, "".decodeHex(), "".decodeHex()) == null;
	assert gcmOpen(xk, new Array<uint8>(27), "".decodeHex()) == null;
}

function refuses(run: () => void): boolean {
	try {
		run();
	} catch (error) {
		return true;
	}
	return false;
}

test "bad key, nonce and iv lengths are refused" {
	assert refuses(() => { expandKey(new Array<uint8>(20)); });
	assert refuses(() => { expandKeyDecrypt(new Array<uint8>(0)); });
	const xk = expandKey(k128z.decodeHex());
	assert refuses(() => { gcmSealWithNonce(xk, new Array<uint8>(16), "".decodeHex(), "".decodeHex()); });
	assert refuses(() => { cbcEncrypt(xk, new Array<uint8>(12), "".decodeHex()); });
	assert refuses(() => { cbcDecrypt(xk, new Array<uint8>(15), new Array<uint8>(16)); });
}

test "GHASH alone over 256 bytes, whole and split" {
	const key = "42424242424242424242424242424242".decodeHex();
	const message = new Array<uint8>(256);
	message.fill(0x69);
	const whole = newGhash(key);
	updateGhash(whole, message, 0, 256);
	const out = new Array<uint8>(16);
	finishGhash(whole, out, 0);
	assert eqHex(out, "889295fa746e8b174bf4ec80a65dea41");
	const split = newGhash(key);
	updateGhash(split, message, 0, 96);
	updateGhash(split, message, 96, 256);
	finishGhash(split, out, 0);
	assert eqHex(out, "889295fa746e8b174bf4ec80a65dea41");
}

test "GCM encrypt and decrypt into caller ranges, in place" {
	const xk = expandKey(k128f.decodeHex());
	const pt = "d9313225f88406e5a55909c5aff5269a86a7a9531534f7da2e4c303d8a318a721c3c0c95956809532fcf0e2449a6b525b16aedf5aa0de657ba637b39";
	const record = new Array<uint8>(5 + 60 + 16);
	const plain = pt.decodeHex();
	for (let i = 0; i < 60; i++) record[5 + i] = plain[i];
	gcmEncryptInto(xk, ivCafe.decodeHex(), aadF.decodeHex(), record, 5, 60, record, 5, record, 65);
	assert eqHex(record.slice(5, 65), "42831ec2217774244b7221b784d0d49ce3aa212f2c02a4e035c17e2329aca12e21d514b25466931c7d8f6a5aac84aa051ba30b396a0aac973d58e091");
	assert eqHex(record.slice(65, 81), "5bc94fbc3221a5db94fae95ae7121a47");
	assert !gcmDecryptInto(xk, ivCafe.decodeHex(), "".decodeHex(), record, 5, 60, record, 65, record, 5);
	assert gcmDecryptInto(xk, ivCafe.decodeHex(), aadF.decodeHex(), record, 5, 60, record, 65, record, 5);
	assert eqHex(record.slice(5, 65), pt);
}

test "GCM sealAt seals a record in place and refuses a bad nonce or range without writing" {
	const xk = expandKey(k128f.decodeHex());
	const pt = "d9313225f88406e5a55909c5aff5269a86a7a9531534f7da2e4c303d8a318a721c3c0c95956809532fcf0e2449a6b525b16aedf5aa0de657ba637b39";
	const record = new Array<uint8>(5 + 60 + 16);
	const plain = pt.decodeHex();
	for (let i = 0; i < 60; i++) record[5 + i] = plain[i];
	assert gcmSealAt(xk, ivCafe.decodeHex(), aadF.decodeHex(), record, 5, 60);
	assert eqHex(record.slice(5, 65), "42831ec2217774244b7221b784d0d49ce3aa212f2c02a4e035c17e2329aca12e21d514b25466931c7d8f6a5aac84aa051ba30b396a0aac973d58e091");
	assert eqHex(record.slice(65, 81), "5bc94fbc3221a5db94fae95ae7121a47");
	const before = record.encodeHex();
	assert !gcmSealAt(xk, ivCafe.decodeHex().slice(0, 11), aadF.decodeHex(), record, 5, 60);
	assert !gcmSealAt(xk, ivCafe.decodeHex(), aadF.decodeHex(), record, 6, 60);
	assert !gcmSealAt(xk, ivCafe.decodeHex(), aadF.decodeHex(), record, -1, 60);
	assert record.encodeHex() == before;
}

test "GCM decryptInto does not write dst on tag failure" {
	const xk     = expandKey(k128f.decodeHex());
	const nonce  = ivCafe.decodeHex();
	const aad    = aadF.decodeHex();
	const pt     = "d9313225f88406e5a55909c5aff5269a".decodeHex();
	const srcBuf = new Array<uint8>(32);
	gcmEncryptInto(xk, nonce, aad, pt, 0, 16, srcBuf, 0, srcBuf, 16);
	srcBuf[16] = (srcBuf[16] ^ 1) as uint8;
	const dst = new Array<uint8>(16);
	dst.fill(0xaa);
	assert !gcmDecryptInto(xk, nonce, aad, srcBuf, 0, 16, srcBuf, 16, dst, 0);
	for (let i = 0; i < 16; i++) assert (dst[i] as int32) == 0xaa;
}

test "GCM decryptInto does not write dst on tag failure, src and dst aliased" {
	const xk    = expandKey(k128f.decodeHex());
	const nonce = ivCafe.decodeHex();
	const aad   = aadF.decodeHex();
	const pt    = "d9313225f88406e5a55909c5aff5269a".decodeHex();
	const buf   = new Array<uint8>(32);
	gcmEncryptInto(xk, nonce, aad, pt, 0, 16, buf, 0, buf, 16);
	const ctHex = buf.slice(0, 16).encodeHex();
	buf[16] = (buf[16] ^ 1) as uint8;
	assert !gcmDecryptInto(xk, nonce, aad, buf, 0, 16, buf, 16, buf, 0);
	assert eqHex(buf.slice(0, 16), ctHex);
}

test "GCM into refuses a range outside its array" {
	const xk = expandKey(k128z.decodeHex());
	const nonce = ivZ.decodeHex();
	const buf = new Array<uint8>(32);
	assert refuses(() => { gcmEncryptInto(xk, nonce, buf, buf, 20, 16, buf, 0, buf, 16); });
	assert refuses(() => { gcmEncryptInto(xk, nonce, buf, buf, 0, -1, buf, 0, buf, 16); });
	assert refuses(() => { gcmEncryptInto(xk, nonce, buf, buf, 0, 16, buf, 0, buf, 17); });
	assert refuses(() => { gcmDecryptInto(xk, nonce, buf, buf, 0, 16, buf, 16, buf, 24); });
}
