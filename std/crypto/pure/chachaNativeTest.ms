import { keyWords, xchachaSealInto, xchachaOpenInto, chacha20Xor, chacha20Poly1305SealInto, chacha20Poly1305OpenInto } from "./chacha";
import { newPoly1305, updatePoly1305, finishPoly1305 } from "./poly1305";

test "xchacha20poly1305 seal matches the published ciphertext and tag" {
	const kw = new Array<uint32>(8);
	keyWords("45".repeat(32).decodeHex(), kw);
	const aad = "4164646974696f6e616c2064617461".decodeHex();
	const plain = "4c616469657320616e642047656e746c656d656e206f662074686520636c617373206f66202739393a204966204920636f756c64206f6666657220796f75206f6e6c79206f6e652074697020666f7220746865206675747572652c2073756e73637265656e20776f756c642062652069742e".decodeHex();
	const out = new Array<uint8>(154);
	for (let i = 0; i < 24; i++) out[i] = 0x2a;
	xchachaSealInto(kw, aad, plain, out);
	assert out.encodeHex() == "2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a994d2dd32333f48e53650c02c7a2abb8e018b0836d7175aec779f52e961780768f815c58f1aa52d211498db89b9216763f569c9433a6bbfcefb4d4a49387a4c5207fbb3b5a92b5941294df30588c6740d39dc16fa1f0e634f7246cf7cdcb978e44347d89381b7a74eb7084f754b90bde9aaf5a94b8f2a85efd0b50692ae2d425e234";
}

test "xchacha20poly1305 open recovers the published plaintext" {
	const kw = new Array<uint32>(8);
	keyWords("45".repeat(32).decodeHex(), kw);
	const aad = "4164646974696f6e616c2064617461".decodeHex();
	const sealed = "2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a994d2dd32333f48e53650c02c7a2abb8e018b0836d7175aec779f52e961780768f815c58f1aa52d211498db89b9216763f569c9433a6bbfcefb4d4a49387a4c5207fbb3b5a92b5941294df30588c6740d39dc16fa1f0e634f7246cf7cdcb978e44347d89381b7a74eb7084f754b90bde9aaf5a94b8f2a85efd0b50692ae2d425e234".decodeHex();
	const plain = new Array<uint8>(114);
	assert xchachaOpenInto(kw, aad, sealed, plain);
	assert plain.encodeHex() == "4c616469657320616e642047656e746c656d656e206f662074686520636c617373206f66202739393a204966204920636f756c64206f6666657220796f75206f6e6c79206f6e652074697020666f7220746865206675747572652c2073756e73637265656e20776f756c642062652069742e";
}

test "empty message: seal and open roundtrip" {
	const kw = new Array<uint32>(8);
	keyWords("45".repeat(32).decodeHex(), kw);
	const aad = "4164646974696f6e616c2064617461".decodeHex();
	const plain: uint8[] = [];
	const sealed = new Array<uint8>(40);
	for (let i = 0; i < 24; i++) sealed[i] = 0x2a;
	xchachaSealInto(kw, aad, plain, sealed);
	const recovered: uint8[] = [];
	assert xchachaOpenInto(kw, aad, sealed, recovered);
}

test "1-byte plaintext: partial-block seal and open roundtrip" {
	const kw = new Array<uint32>(8);
	keyWords("45".repeat(32).decodeHex(), kw);
	const aad = "4164646974696f6e616c2064617461".decodeHex();
	const plain: uint8[] = [0xab];
	const sealed = new Array<uint8>(41);
	for (let i = 0; i < 24; i++) sealed[i] = 0x2a;
	xchachaSealInto(kw, aad, plain, sealed);
	const recovered = new Array<uint8>(1);
	assert xchachaOpenInto(kw, aad, sealed, recovered);
	assert recovered[0] == 0xab;
}

test "tampered ciphertext byte is rejected" {
	const kw = new Array<uint32>(8);
	keyWords("45".repeat(32).decodeHex(), kw);
	const aad = "4164646974696f6e616c2064617461".decodeHex();
	let sealed = "2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a994d2dd32333f48e53650c02c7a2abb8e018b0836d7175aec779f52e961780768f815c58f1aa52d211498db89b9216763f569c9433a6bbfcefb4d4a49387a4c5207fbb3b5a92b5941294df30588c6740d39dc16fa1f0e634f7246cf7cdcb978e44347d89381b7a74eb7084f754b90bde9aaf5a94b8f2a85efd0b50692ae2d425e234".decodeHex();
	sealed[24] = (sealed[24] ^ 1) as uint8;
	const out = new Array<uint8>(114);
	assert !xchachaOpenInto(kw, aad, sealed, out);
}

test "wrong AAD is rejected" {
	const kw = new Array<uint32>(8);
	keyWords("45".repeat(32).decodeHex(), kw);
	const sealed = "2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a994d2dd32333f48e53650c02c7a2abb8e018b0836d7175aec779f52e961780768f815c58f1aa52d211498db89b9216763f569c9433a6bbfcefb4d4a49387a4c5207fbb3b5a92b5941294df30588c6740d39dc16fa1f0e634f7246cf7cdcb978e44347d89381b7a74eb7084f754b90bde9aaf5a94b8f2a85efd0b50692ae2d425e234".decodeHex();
	const wrongAad: uint8[] = [];
	const out = new Array<uint8>(114);
	assert !xchachaOpenInto(kw, wrongAad, sealed, out);
}

function rfcKey(hex: string): uint32[] {
	const kw = new Array<uint32>(8);
	if (!keyWords(hex.decodeHex(), kw)) throw new Error("rfcKey: key must be 32 bytes");
	return kw;
}

function poly1305Of(keyHex: string, msgHex: string): string {
	const msg = msgHex.decodeHex();
	const mac = newPoly1305(keyHex.decodeHex(), 0);
	updatePoly1305(mac, msg, 0, msg.length as int32);
	const tag = new Array<uint8>(16);
	finishPoly1305(mac, tag, 0);
	return tag.encodeHex();
}

function patterned(size: int32): uint8[] {
	const out = new Array<uint8>(size);
	for (let i = 0; i < size; i++) out[i] = ((i * 7 + 3) & 255) as uint8;
	return out;
}

test "chacha20 block function matches RFC 8439 2.3.2" {
	const kw = rfcKey("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f");
	const zeros = new Array<uint8>(64);
	const out = new Array<uint8>(64);
	assert chacha20Xor(kw, "000000090000004a00000000".decodeHex(), 1, zeros, out);
	assert out.encodeHex() == "10f1e7e4d13b5915500fdd1fa32071c4c7d1f4c733c068030422aa9ac3d46c4ed2826446079faa0914c2d705d98b02a2b5129cd1de164eb9cbd083e8a2503c4e";
}

test "chacha20 encryption matches RFC 8439 2.4.2 and decrypts back" {
	const kw = rfcKey("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f");
	const nonce = "000000000000004a00000000".decodeHex();
	const plain = "4c616469657320616e642047656e746c656d656e206f662074686520636c617373206f66202739393a204966204920636f756c64206f6666657220796f75206f6e6c79206f6e652074697020666f7220746865206675747572652c2073756e73637265656e20776f756c642062652069742e".decodeHex();
	const cipher = new Array<uint8>(114);
	assert chacha20Xor(kw, nonce, 1, plain, cipher);
	assert cipher.encodeHex() == "6e2e359a2568f98041ba0728dd0d6981e97e7aec1d4360c20a27afccfd9fae0bf91b65c5524733ab8f593dabcd62b3571639d624e65152ab8f530c359f0861d807ca0dbf500d6a6156a38e088a22b65e52bc514d16ccf806818ce91ab77937365af90bbf74a35be6b40b8eedf2785e42874d";
	const back = new Array<uint8>(114);
	assert chacha20Xor(kw, nonce, 1, cipher, back);
	assert back.encodeHex() == plain.encodeHex();
}

test "poly1305 matches RFC 8439 2.5.2 and a vector that needs the final reduction" {
	assert poly1305Of("85d6be7857556d337f4452fe42d506a80103808afb0db2fd4abff6af4149f51b", "43727970746f6772617068696320466f72756d2052657365617263682047726f7570") == "a8061dc1305136c6c22b8baf0c0127a9";
	assert poly1305Of("be3f5f399b674daa07626a2c75ba5ab96d76b8184529a6f37784973d342b40fa", "fdc1f9924606d6e283d5f1741418d2e04197ff6885") == "190df92aa439633c95b54a4a0d3f7906";
}

test "poly1305 of an empty message is the s half of the key" {
	assert poly1305Of("0000000000000000000000000000000036e5f6b5c5e06070f0efca96227a863e", "") == "36e5f6b5c5e06070f0efca96227a863e";
}

test "chacha20poly1305 seal matches RFC 8439 2.8.2 and the empty vector" {
	const kw = rfcKey("808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f");
	const nonce = "070000004041424344454647".decodeHex();
	const out = new Array<uint8>(130);
	assert chacha20Poly1305SealInto(kw, nonce, "50515253c0c1c2c3c4c5c6c7".decodeHex(), "4c616469657320616e642047656e746c656d656e206f662074686520636c617373206f66202739393a204966204920636f756c64206f6666657220796f75206f6e6c79206f6e652074697020666f7220746865206675747572652c2073756e73637265656e20776f756c642062652069742e".decodeHex(), out);
	assert out.encodeHex() == "d31a8d34648e60db7b86afbc53ef7ec2a4aded51296e08fea9e2b5a736ee62d63dbea45e8ca9671282fafb69da92728b1a71de0a9e060b2905d6a5b67ecd3b3692ddbd7f2d778b8c9803aee328091b58fab324e4fad675945585808b4831d7bc3ff4def08e4b7a9de576d26586cec64b61161ae10b594f09e26a7e902ecbd0600691";
	const empty: uint8[] = [];
	const tagOnly = new Array<uint8>(16);
	assert chacha20Poly1305SealInto(kw, nonce, empty, empty, tagOnly);
	assert tagOnly.encodeHex() == "a0784d7a4716f3feb4f64e7f4b39bf04";
}

test "chacha20poly1305 open recovers RFC 8439 2.8.2 and rejects every tampered input" {
	const kw = rfcKey("808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f");
	const nonce = "070000004041424344454647".decodeHex();
	const aad = "50515253c0c1c2c3c4c5c6c7".decodeHex();
	const sealed = "d31a8d34648e60db7b86afbc53ef7ec2a4aded51296e08fea9e2b5a736ee62d63dbea45e8ca9671282fafb69da92728b1a71de0a9e060b2905d6a5b67ecd3b3692ddbd7f2d778b8c9803aee328091b58fab324e4fad675945585808b4831d7bc3ff4def08e4b7a9de576d26586cec64b61161ae10b594f09e26a7e902ecbd0600691".decodeHex();
	const out = new Array<uint8>(114);
	assert chacha20Poly1305OpenInto(kw, nonce, aad, sealed, out);
	assert out.encodeHex() == "4c616469657320616e642047656e746c656d656e206f662074686520636c617373206f66202739393a204966204920636f756c64206f6666657220796f75206f6e6c79206f6e652074697020666f7220746865206675747572652c2073756e73637265656e20776f756c642062652069742e";

	const badCipher = "d31a8d34648e60db7b86afbc53ef7ec2a4aded51296e08fea9e2b5a736ee62d63dbea45e8ca9671282fafb69da92728b1a71de0a9e060b2905d6a5b67ecd3b3692ddbd7f2d778b8c9803aee328091b58fab324e4fad675945585808b4831d7bc3ff4def08e4b7a9de576d26586cec64b61161ae10b594f09e26a7e902ecbd0600691".decodeHex();
	badCipher[0] = (badCipher[0] ^ 1) as uint8;
	assert !chacha20Poly1305OpenInto(kw, nonce, aad, badCipher, out);
	const badTag = "d31a8d34648e60db7b86afbc53ef7ec2a4aded51296e08fea9e2b5a736ee62d63dbea45e8ca9671282fafb69da92728b1a71de0a9e060b2905d6a5b67ecd3b3692ddbd7f2d778b8c9803aee328091b58fab324e4fad675945585808b4831d7bc3ff4def08e4b7a9de576d26586cec64b61161ae10b594f09e26a7e902ecbd0600691".decodeHex();
	badTag[129] = (badTag[129] ^ 0x80) as uint8;
	assert !chacha20Poly1305OpenInto(kw, nonce, aad, badTag, out);
	const badAad = "50515253c0c1c2c3c4c5c6c7".decodeHex();
	badAad[0] = (badAad[0] ^ 1) as uint8;
	assert !chacha20Poly1305OpenInto(kw, nonce, badAad, sealed, out);
	const badKey = rfcKey("818182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f");
	assert !chacha20Poly1305OpenInto(badKey, nonce, aad, sealed, out);
	const badNonce = "060000004041424344454647".decodeHex();
	assert !chacha20Poly1305OpenInto(kw, badNonce, aad, sealed, out);
}

test "wrong key, nonce and buffer lengths are refused" {
	const kw = new Array<uint32>(8);
	assert !keyWords("00".repeat(31).decodeHex(), kw);
	assert !keyWords("00".repeat(33).decodeHex(), kw);
	const key = rfcKey("00".repeat(32));
	const empty: uint8[] = [];
	const tagOnly = new Array<uint8>(16);
	assert !chacha20Poly1305SealInto(key, "00".repeat(11).decodeHex(), empty, empty, tagOnly);
	assert !chacha20Poly1305SealInto(key, "00".repeat(24).decodeHex(), empty, empty, tagOnly);
	assert !chacha20Poly1305SealInto(key, "00".repeat(12).decodeHex(), empty, empty, new Array<uint8>(15));
	assert !chacha20Poly1305OpenInto(key, "00".repeat(12).decodeHex(), empty, new Array<uint8>(15), empty);
	assert !chacha20Xor(key, "00".repeat(8).decodeHex(), 0, empty, empty);
	assert !xchachaSealInto(key, empty, empty, new Array<uint8>(39));
	assert !xchachaOpenInto(key, empty, new Array<uint8>(39), empty);
}

test "both AEADs roundtrip and reject a flipped tag at block edges" {
	const key = rfcKey("45".repeat(32));
	const nonce = "2a".repeat(12).decodeHex();
	const aad = "616164".decodeHex();
	for (const size of [0, 1, 15, 16, 17, 63, 64, 65, 127, 128, 129]) {
		const plain = patterned(size);
		const sealed = new Array<uint8>(size + 16);
		assert chacha20Poly1305SealInto(key, nonce, aad, plain, sealed);
		const back = new Array<uint8>(size);
		assert chacha20Poly1305OpenInto(key, nonce, aad, sealed, back);
		assert back.encodeHex() == plain.encodeHex();
		sealed[size + 15] = (sealed[size + 15] ^ 1) as uint8;
		assert !chacha20Poly1305OpenInto(key, nonce, aad, sealed, back);

		const xsealed = new Array<uint8>(size + 40);
		for (let i = 0; i < 24; i++) xsealed[i] = 0x2a;
		assert xchachaSealInto(key, aad, plain, xsealed);
		const xback = new Array<uint8>(size);
		assert xchachaOpenInto(key, aad, xsealed, xback);
		assert xback.encodeHex() == plain.encodeHex();
		xsealed[size + 39] = (xsealed[size + 39] ^ 1) as uint8;
		assert !xchachaOpenInto(key, aad, xsealed, xback);
	}
}

test "chacha20 keystream continues across the 64-byte block boundary" {
	const key = rfcKey("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f");
	const nonce = "000000090000004a00000000".decodeHex();
	const whole = new Array<uint8>(130);
	assert chacha20Xor(key, nonce, 1, new Array<uint8>(130), whole);
	const second = new Array<uint8>(66);
	assert chacha20Xor(key, nonce, 2, new Array<uint8>(66), second);
	for (let i = 0; i < 66; i++) assert whole[64 + i] == second[i];
	assert whole.slice(0, 64).encodeHex() == "10f1e7e4d13b5915500fdd1fa32071c4c7d1f4c733c068030422aa9ac3d46c4ed2826446079faa0914c2d705d98b02a2b5129cd1de164eb9cbd083e8a2503c4e";
}
