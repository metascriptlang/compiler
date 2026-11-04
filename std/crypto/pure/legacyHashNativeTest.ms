import { kindSha1, kindMd5 } from "./state";
import { newHash, updateHash, finishHash, hashOf } from "./hash";
import { encodeHex } from "../../core/encoding";

function hex(kind: int32, text: string): string {
	return hashOf(kind, text.asBytes().slice(0)).encodeHex();
}

function repeated(n: int32): string {
	let s = "";
	for (let i = 0; i < n; i++) s += "a";
	return s;
}

test "sha1 RFC 3174 and FIPS 180 vectors" {
	assert hex(kindSha1, "") == "da39a3ee5e6b4b0d3255bfef95601890afd80709";
	assert hex(kindSha1, "abc") == "a9993e364706816aba3e25717850c26c9cd0d89d";
	assert hex(kindSha1, "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq") == "84983e441c3bd26ebaae4aa1f95129e5e54670f1";
	assert hex(kindSha1, "0123456701234567012345670123456701234567012345670123456701234567") == "e0c094e867ef46c350ef54a7f59dd60bed92ae83";
}

test "md5 RFC 1321 suite" {
	assert hex(kindMd5, "") == "d41d8cd98f00b204e9800998ecf8427e";
	assert hex(kindMd5, "a") == "0cc175b9c0f1b6a831c399e269772661";
	assert hex(kindMd5, "abc") == "900150983cd24fb0d6963f7d28e17f72";
	assert hex(kindMd5, "message digest") == "f96b697d7cb7938d525a2f31aaf161d0";
	assert hex(kindMd5, "abcdefghijklmnopqrstuvwxyz") == "c3fcd3d76192e4007dfb496cca67e13b";
	assert hex(kindMd5, "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789") == "d174ab98d277d9f5a5611c2c9f419d9f";
	assert hex(kindMd5, "12345678901234567890123456789012345678901234567890123456789012345678901234567890") == "57edf4a22be3c955ac49da2e2107b67a";
}

test "block boundaries" {
	assert hex(kindSha1, repeated(55)) == "c1c8bbdc22796e28c0e15163d20899b65621d65a";
	assert hex(kindMd5, repeated(55)) == "ef1772b6dff9a122358552954ad0df65";
	assert hex(kindSha1, repeated(56)) == "c2db330f6083854c99d4b5bfb6e8f29f201be699";
	assert hex(kindMd5, repeated(56)) == "3b0c8ac703f828b04c6c197006d17218";
	assert hex(kindSha1, repeated(63)) == "03f09f5b158a7a8cdad920bddc29b81c18a551f5";
	assert hex(kindMd5, repeated(63)) == "b06521f39153d618550606be297466d5";
	assert hex(kindSha1, repeated(64)) == "0098ba824b5c16427bd7a1122a5a442a25ec644d";
	assert hex(kindMd5, repeated(64)) == "014842d480b571495a4a0363793f7367";
	assert hex(kindSha1, repeated(65)) == "11655326c708d70319be2610e8a57d9a5b959d3b";
	assert hex(kindMd5, repeated(65)) == "c743a45e0d2e6a95cb859adae0248435";
}

test "streaming split equals one-shot" {
	const text = "The quick brown fox jumps over the lazy dog, then again and again across blocks.".asBytes().slice(0);
	const kinds: int32[] = [kindSha1, kindMd5];
	for (const kind of kinds) {
		const whole = hashOf(kind, text).encodeHex();
		for (let cut = 0; cut <= text.length; cut += 7) {
			const h = newHash(kind);
			updateHash(h, text.slice(0, cut));
			updateHash(h, text.slice(cut));
			assert finishHash(h).encodeHex() == whole;
		}
	}
}
