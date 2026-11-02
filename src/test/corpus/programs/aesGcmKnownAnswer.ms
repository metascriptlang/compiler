// AES-GCM `open` agrees with the NIST SP 800-38D / McGrew-Viega test vectors (cases 2, 4, 14, 16),
// whose blobs are written as nonce || cipherText || tag, the layout `seal` emits. A flipped tag
// bit, a flipped cipher text bit and a missing AAD must each refuse the blob.
//
// @stdout: sealed by the hand-written implementation opens true
// @stdout: case2 aes128 opens true tag false body false aad false|case4 aes128 opens true tag false body false aad false|case14 aes256 opens true tag false body false aad false|case16 aes256 opens true tag false body false aad false
// @exit: 0
// @skip-raiser: std/crypto/aes has only a C backend (index.cms over mbedTLS); there is no aes.rms

import { Buffer } from "std/core/buffer";
import { AesKey, open } from "std/crypto/aes";

const message = "d9313225f88406e5a55909c5aff5269a86a7a9531534f7da2e4c303d8a318a721c3c0c95956809532fcf0e2449a6b525b16aedf5aa0de657ba637b39";
const header = "feedfacedeadbeeffeedfacedeadbeefabaddad2";
const nonce = "cafebabefacedbaddecaf888";
const zeroNonce = "000000000000000000000000";

function flip(blob: Buffer, index: int32): Buffer {
	const copy = Buffer.copy(blob);
	copy[index] = (copy[index] ^ 1) as uint8;
	return copy;
}

function flipLast(blob: Buffer): Buffer {
	return flip(blob, blob.length - 1);
}

function fromHex(hex: string): Buffer {
	return Buffer.fromString(hex, "hex");
}

function importKey(raw: Buffer): AesKey {
	const imported = AesKey.import(raw);
	if (!imported.ok) throw new Error("import failed");
	return imported.value;
}

async function row(name: string, keyHex: string, blobHex: string, plainHex: string, aadHex: string): Promise<string> {
	const key = importKey(fromHex(keyHex));
	const blob = fromHex(blobHex);
	const aad = fromHex(aadHex);
	const opened = await open(key, blob, aad);
	const opens = opened.ok && opened.value.toHex() == plainHex;
	const tag = (await open(key, flipLast(blob), aad)).ok;
	const body = (await open(key, flip(blob, 12), aad)).ok;
	const noAad = aadHex == "" ? false : (await open(key, blob, "")).ok;
	return `${name} aes${keyHex.length * 4} opens ${opens} tag ${tag} body ${body} aad ${noAad}`;
}

const key128 = "feffe9928665731c6d6a8f9467308308";
const hand = await open(importKey(fromHex("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")), fromHex("360d1b19209166536bd242bdbff91fac9528384156886cfa061f42e7f86abd6c425f5beb9bf7608135c222cce42e573de90f8f2a31075ac9"), "hdr");
console.log(`sealed by the hand-written implementation opens ${hand.ok && hand.value.asString() == "attack at dawn, bring snacks"}`);
console.log([
	await row("case2", "00".repeat(16), zeroNonce + "0388dace60b6a392f328c2b971b2fe78" + "ab6e47d42cec13bdf53a67b21257bddf", "00".repeat(16), ""),
	await row("case4", key128, nonce + "42831ec2217774244b7221b784d0d49ce3aa212f2c02a4e035c17e2329aca12e21d514b25466931c7d8f6a5aac84aa051ba30b396a0aac973d58e091" + "5bc94fbc3221a5db94fae95ae7121a47", message, header),
	await row("case14", "00".repeat(32), zeroNonce + "cea7403d4d606b6e074ec5d3baf39d18" + "d0d1c8a799996bf0265b98b5d48ab919", "00".repeat(16), ""),
	await row("case16", key128 + key128, nonce + "522dc1f099567d07f47f37a32a84427d643a8cdcbfe5c0c97598a2bd2555d1aa8cb08e48590dbb3da7b08b1056828838c5f61e6393ba7a0abcc9f662" + "76fc6ece0f4e1768cddf8853bb2d551b", message, header),
].join("|"));
