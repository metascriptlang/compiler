import { newBlake2b, updateBlake2b, finishBlake2b, blake2bOf } from "./blake2b";
import { encodeHex, decodeHex } from "../../core/encoding";

function katKey(): uint8[] {
	const k = new Array<uint8>(64);
	for (let i = 0; i < 64; i++) k[i] = i as uint8;
	return k;
}

function seqBytes(n: int32): uint8[] {
	const b = new Array<uint8>(n);
	for (let i = 0; i < n; i++) b[i] = (i & 0xff) as uint8;
	return b;
}

test "BLAKE2b-512 unkeyed empty" {
	assert blake2bOf(64, new Array<uint8>(0), new Array<uint8>(0)).encodeHex()
		== "786a02f742015903c6c6fd852552d272912f4740e15847618a86e217f71f5419d25e1031afee585313896444934eb04b903a685b1448b755d56f701afe9be2ce";
}

test "BLAKE2b-512 unkeyed abc" {
	assert blake2bOf(64, new Array<uint8>(0), "616263".decodeHex()).encodeHex()
		== "ba80a53f981c4d0d6a2797b69f12f6e94c212f14685ac4b74b12bb6fdbffa2d17d87c5392aab792dc252d5de4533cc9518d38aa8dbf1925ab92386edd4009923";
}

test "BLAKE2b-512 unkeyed 128 bytes 64x0x61 followed by 64x0x62" {
	const data = new Array<uint8>(128);
	for (let i = 0; i < 64; i++) data[i] = 0x61 as uint8;
	for (let i = 0; i < 64; i++) data[64 + i] = 0x62 as uint8;
	assert blake2bOf(64, new Array<uint8>(0), data).encodeHex()
		== "049980af04d6a2cf16b4b49793c3ed7e40732073788806f2c989ebe9547bda0541d63abe298ec8955d08af48ae731f2e8a0bd6d201655a5473b4aa79d211b920";
}

test "BLAKE2b-512 keyed secret_key 128 bytes 64x0x61 followed by 64x0x62" {
	const key = "7365637265745f6b6579".decodeHex();
	const data = new Array<uint8>(128);
	for (let i = 0; i < 64; i++) data[i] = 0x61 as uint8;
	for (let i = 0; i < 64; i++) data[64 + i] = 0x62 as uint8;
	assert blake2bOf(64, key, data).encodeHex()
		== "8a978060ccaf582f388f37454363071ac9a67e3a704585fd879fb8a419a447e389c7c6de790faa20a7a7dccf197de736bc5b40b98a930b36df5bee7555750c4d";
}

// katKey() = 0x00..0x3f; vectors from the official BLAKE2b-kat.txt
// (vendored at vendor/monocypher/tests/gen/vectors/blake2b)

test "BLAKE2b-512 keyed KAT-key empty" {
	assert blake2bOf(64, katKey(), new Array<uint8>(0)).encodeHex()
		== "10ebb67700b1868efb4417987acf4690ae9d972fb7a590c2f02871799aaa4786b5e996e8f0f4eb981fc214b005f42d2ff4233499391653df7aefcbc13fc51568";
}

test "BLAKE2b-512 keyed KAT-key 1 byte 0x00" {
	assert blake2bOf(64, katKey(), "00".decodeHex()).encodeHex()
		== "961f6dd1e4dd30f63901690c512e78e4b45e4742ed197c3c5e45c549fd25f2e4187b0bc9fe30492b16b0d0bc4ef9b0f34c7003fac09a5ef1532e69430234cebd";
}

test "BLAKE2b-512 keyed KAT-key 128 bytes 0x00-0x7f one full block" {
	assert blake2bOf(64, katKey(), seqBytes(128)).encodeHex()
		== "72065ee4dd91c2d8509fa1fc28a37c7fc9fa7d5b3f8ad3d0d7a25626b57b1b44788d4caf806290425f9890a3a2a35a905ab4b37acfd0da6e4517b2525c9651e4";
}

test "BLAKE2b-512 keyed KAT-key 129 bytes 0x00-0x80 one block plus one byte" {
	assert blake2bOf(64, katKey(), seqBytes(129)).encodeHex()
		== "64475dfe7600d7171bea0b394e27c9b00d8e74dd1e416a79473682ad3dfdbb706631558055cfc8a40e07bd015a4540dcdea15883cbbf31412df1de1cd4152b91";
}

// outputSize=20 and outputSize=48: Zig blake2.zig commit 16d31ceed5 lib/std/crypto/blake2.zig

test "BLAKE2b-160 unkeyed empty" {
	assert blake2bOf(20, new Array<uint8>(0), new Array<uint8>(0)).encodeHex()
		== "3345524abf6bbe1809449224b5972c41790b6cf2";
}

test "BLAKE2b-160 unkeyed abc" {
	assert blake2bOf(20, new Array<uint8>(0), "616263".decodeHex()).encodeHex()
		== "384264f676f39536840523f284921cdc68b6846b";
}

test "BLAKE2b-384 unkeyed empty" {
	assert blake2bOf(48, new Array<uint8>(0), new Array<uint8>(0)).encodeHex()
		== "b32811423377f52d7862286ee1a72ee540524380fda1724a6f25d7978c6fd3244a6caf0498812673c5e05ef583825100";
}

test "BLAKE2b-384 unkeyed abc" {
	assert blake2bOf(48, new Array<uint8>(0), "616263".decodeHex()).encodeHex()
		== "6f56a82c8e7ef526dfe182eb5212f7db9df1317e57815dbda46083fc30f54ee6c66ba83be64b302d7cba6ce15bb556f4";
}

test "BLAKE2b-8 unkeyed empty" {
	assert blake2bOf(1, new Array<uint8>(0), new Array<uint8>(0)).encodeHex()
		== "2e";
}

test "BLAKE2b-8 unkeyed abc" {
	assert blake2bOf(1, new Array<uint8>(0), "616263".decodeHex()).encodeHex()
		== "6b";
}

test "BLAKE2b-256 unkeyed empty" {
	assert blake2bOf(32, new Array<uint8>(0), new Array<uint8>(0)).encodeHex()
		== "0e5751c026e543b2e8ab2eb06099daa1d1e5df47778f7787faab45cdf12fe3a8";
}

test "BLAKE2b-256 unkeyed abc" {
	assert blake2bOf(32, new Array<uint8>(0), "616263".decodeHex()).encodeHex()
		== "bddd813c634239723171ef3fee98579b94964e3bb1cb3e427262c8c068d52319";
}

test "streaming abc in three 1-byte updates matches one-shot" {
	const abc = "616263".decodeHex();
	const s = newBlake2b(64, new Array<uint8>(0));
	updateBlake2b(s, abc, 0, 1);
	updateBlake2b(s, abc, 1, 1);
	updateBlake2b(s, abc, 2, 1);
	assert finishBlake2b(s).encodeHex()
		== "ba80a53f981c4d0d6a2797b69f12f6e94c212f14685ac4b74b12bb6fdbffa2d17d87c5392aab792dc252d5de4533cc9518d38aa8dbf1925ab92386edd4009923";
}

test "streaming KAT 128-byte input split at 64 matches one-shot" {
	const data = seqBytes(128);
	const s = newBlake2b(64, katKey());
	updateBlake2b(s, data, 0, 64);
	updateBlake2b(s, data, 64, 64);
	assert finishBlake2b(s).encodeHex()
		== "72065ee4dd91c2d8509fa1fc28a37c7fc9fa7d5b3f8ad3d0d7a25626b57b1b44788d4caf806290425f9890a3a2a35a905ab4b37acfd0da6e4517b2525c9651e4";
}

test "streaming KAT 129-byte input split at 128 and 1 matches one-shot" {
	const data = seqBytes(129);
	const s = newBlake2b(64, katKey());
	updateBlake2b(s, data, 0, 128);
	updateBlake2b(s, data, 128, 1);
	assert finishBlake2b(s).encodeHex()
		== "64475dfe7600d7171bea0b394e27c9b00d8e74dd1e416a79473682ad3dfdbb706631558055cfc8a40e07bd015a4540dcdea15883cbbf31412df1de1cd4152b91";
}

test "finished flag is clear before and set after finishBlake2b" {
	const s = newBlake2b(64, new Array<uint8>(0));
	assert !s.finished;
	updateBlake2b(s, "616263".decodeHex(), 0, 3);
	assert !s.finished;
	finishBlake2b(s);
	assert s.finished;
}

function updateRefused(off: int32, length: int32): boolean {
	const s = newBlake2b(32, new Array<uint8>(0));
	try {
		updateBlake2b(s, "616263".decodeHex(), off, length);
	} catch (e) {
		return true;
	}
	return false;
}

test "updateBlake2b refuses a negative or out-of-range slice" {
	assert updateRefused(-1, 1);
	assert updateRefused(0, -1);
	assert updateRefused(2, 2);
	assert !updateRefused(3, 0);
}
