import { encodeHex } from "../../core/encoding";
import { newHash, updateHash, finishHash, hashOf } from "./hash";
import { kindSha256, kindSha224, kindSha512, kindSha384, kindSha1, kindMd5 } from "./state";

function bytes(s: string): uint8[] {
	return s.asBytes().slice(0);
}

function fill(n: int32, b: uint8): uint8[] {
	const arr = new Array<uint8>(n);
	for (let i = 0; i < n; i++) arr[i] = b;
	return arr;
}

test "sha256 NIST FIPS 180-4 vectors" {
	assert hashOf(kindSha256, bytes("")).encodeHex() == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";
	assert hashOf(kindSha256, bytes("abc")).encodeHex() == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
	assert hashOf(kindSha256, bytes("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")).encodeHex() == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1";
	assert hashOf(kindSha256, bytes("abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu")).encodeHex() == "cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1";
}

test "sha224 NIST FIPS 180-4 vectors" {
	assert hashOf(kindSha224, bytes("")).encodeHex() == "d14a028c2a3a2bc9476102bb288234c415a2b01f828ea62ac5b3e42f";
	assert hashOf(kindSha224, bytes("abc")).encodeHex() == "23097d223405d8228642a477bda255b32aadbce4bda0b3f7e36c9da7";
	assert hashOf(kindSha224, bytes("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")).encodeHex() == "75388b16512776cc5dba5da1fd890150b0c6455cb4f58b1952522525";
	assert hashOf(kindSha224, bytes("abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu")).encodeHex() == "c97ca9a559850ce97a04a96def6d99a9e0e0e2ab14e6b8df265fc0b3";
}

test "sha512 NIST FIPS 180-4 vectors" {
	assert hashOf(kindSha512, bytes("")).encodeHex() == "cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e";
	assert hashOf(kindSha512, bytes("abc")).encodeHex() == "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f";
	assert hashOf(kindSha512, bytes("abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu")).encodeHex() == "8e959b75dae313da8cf4f72814fc143f8f7779c6eb9f7fa17299aeadb6889018501d289e4900f7e4331b99dec4b5433ac7d329eeb6dd26545e96e55b874be909";
}

test "sha384 NIST FIPS 180-4 vectors" {
	assert hashOf(kindSha384, bytes("")).encodeHex() == "38b060a751ac96384cd9327eb1b1e36a21fdb71114be07434c0cc7bf63f6e1da274edebfe76f65fbd51ad2f14898b95b";
	assert hashOf(kindSha384, bytes("abc")).encodeHex() == "cb00753f45a35e8bb5a03d699ac65007272c32ab0eded1631a8b605a43ff5bed8086072ba1e7cc2358baeca134c825a7";
	assert hashOf(kindSha384, bytes("abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu")).encodeHex() == "09330c33f71147e83d192fc782cd1b4753111b173b3b05d22fa08086e3b0f712fcc7c71a557e2db966c3e9fa91746039";
}

test "sha1 NIST FIPS 180-4 vectors" {
	assert hashOf(kindSha1, bytes("")).encodeHex() == "da39a3ee5e6b4b0d3255bfef95601890afd80709";
	assert hashOf(kindSha1, bytes("abc")).encodeHex() == "a9993e364706816aba3e25717850c26c9cd0d89d";
	assert hashOf(kindSha1, bytes("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")).encodeHex() == "84983e441c3bd26ebaae4aa1f95129e5e54670f1";
	assert hashOf(kindSha1, bytes("abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu")).encodeHex() == "a49b2446a02c645bf419f995b67091253a04a259";
}

test "md5 RFC 1321 vectors" {
	assert hashOf(kindMd5, bytes("")).encodeHex() == "d41d8cd98f00b204e9800998ecf8427e";
	assert hashOf(kindMd5, bytes("abc")).encodeHex() == "900150983cd24fb0d6963f7d28e17f72";
	assert hashOf(kindMd5, bytes("message digest")).encodeHex() == "f96b697d7cb7938d525a2f31aaf161d0";
	assert hashOf(kindMd5, bytes("abcdefghijklmnopqrstuvwxyz")).encodeHex() == "c3fcd3d76192e4007dfb496cca67e13b";
	assert hashOf(kindMd5, bytes("12345678901234567890123456789012345678901234567890123456789012345678901234567890")).encodeHex() == "57edf4a22be3c955ac49da2e2107b67a";
}

test "split update sha256 abc" {
	const h = newHash(kindSha256);
	updateHash(h, bytes("a"));
	updateHash(h, bytes("b"));
	updateHash(h, bytes("c"));
	assert finishHash(h).encodeHex() == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
}

test "split update sha512 abc" {
	const h = newHash(kindSha512);
	updateHash(h, bytes("a"));
	updateHash(h, bytes("b"));
	updateHash(h, bytes("c"));
	assert finishHash(h).encodeHex() == "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f";
}

test "split update sha1 abc" {
	const h = newHash(kindSha1);
	updateHash(h, bytes("a"));
	updateHash(h, bytes("b"));
	updateHash(h, bytes("c"));
	assert finishHash(h).encodeHex() == "a9993e364706816aba3e25717850c26c9cd0d89d";
}

test "split update md5 abc" {
	const h = newHash(kindMd5);
	updateHash(h, bytes("a"));
	updateHash(h, bytes("b"));
	updateHash(h, bytes("c"));
	assert finishHash(h).encodeHex() == "900150983cd24fb0d6963f7d28e17f72";
}

test "sha256 split 32+23 bytes" {
	const h = newHash(kindSha256);
	updateHash(h, fill(32, 0x61 as uint8));
	updateHash(h, fill(23, 0x61 as uint8));
	assert finishHash(h).encodeHex() == "9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318";
}

test "sha512 split 64+47 bytes" {
	const h = newHash(kindSha512);
	updateHash(h, fill(64, 0x61 as uint8));
	updateHash(h, fill(47, 0x61 as uint8));
	assert finishHash(h).encodeHex() == "fa9121c7b32b9e01733d034cfc78cbf67f926c7ed83e82200ef86818196921760b4beff48404df811b953828274461673c68d04e297b0eb7b2b4d60fc6b566a2";
}

test "sha256 padding boundaries 55/56/64" {
	assert hashOf(kindSha256, fill(55, 0x61 as uint8)).encodeHex() == "9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318";
	assert hashOf(kindSha256, fill(56, 0x61 as uint8)).encodeHex() == "b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a";
	assert hashOf(kindSha256, fill(64, 0x61 as uint8)).encodeHex() == "ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb";
}

test "sha512 padding boundaries 111/112/128" {
	assert hashOf(kindSha512, fill(111, 0x61 as uint8)).encodeHex() == "fa9121c7b32b9e01733d034cfc78cbf67f926c7ed83e82200ef86818196921760b4beff48404df811b953828274461673c68d04e297b0eb7b2b4d60fc6b566a2";
	assert hashOf(kindSha512, fill(112, 0x61 as uint8)).encodeHex() == "c01d080efd492776a1c43bd23dd99d0a2e626d481e16782e75d54c2503b5dc32bd05f0f1ba33e568b88fd2d970929b719ecbb152f58f130a407c8830604b70ca";
	assert hashOf(kindSha512, fill(128, 0x61 as uint8)).encodeHex() == "b73d1929aa615934e61a871596b3f3b33359f42b8175602e89f7e06e5f658a243667807ed300314b95cacdd579f3e33abdfbe351909519a846d465c59582f321";
}

test "sha224 padding boundaries 55/56/63/64/65" {
	assert hashOf(kindSha224, fill(55, 0x61 as uint8)).encodeHex() == "fb0bd626a70c28541dfa781bb5cc4d7d7f56622a58f01a0b1ddd646f";
	assert hashOf(kindSha224, fill(56, 0x61 as uint8)).encodeHex() == "d40854fc9caf172067136f2e29e1380b14626bf6f0dd06779f820dcd";
	assert hashOf(kindSha224, fill(63, 0x61 as uint8)).encodeHex() == "1d4e051f4d6fed2a63fd2421e65834cec00d64456553de3496ae8b1d";
	assert hashOf(kindSha224, fill(64, 0x61 as uint8)).encodeHex() == "a88cd5cde6d6fe9136a4e58b49167461ea95d388ca2bdb7afdc3cbf4";
	assert hashOf(kindSha224, fill(65, 0x61 as uint8)).encodeHex() == "ff8716f600af42959d0efb52e1f21b01bb328733009344d511c299fb";
}

test "sha256 padding boundaries 63/65" {
	assert hashOf(kindSha256, fill(63, 0x61 as uint8)).encodeHex() == "7d3e74a05d7db15bce4ad9ec0658ea98e3f06eeecf16b4c6fff2da457ddc2f34";
	assert hashOf(kindSha256, fill(65, 0x61 as uint8)).encodeHex() == "635361c48bb9eab14198e76ea8ab7f1a41685d6ad62aa9146d301d4f17eb0ae0";
}

test "sha384 padding boundaries 111/112/127/128/129" {
	assert hashOf(kindSha384, fill(111, 0x61 as uint8)).encodeHex() == "3c37955051cb5c3026f94d551d5b5e2ac38d572ae4e07172085fed81f8466b8f90dc23a8ffcdea0b8d8e58e8fdacc80a";
	assert hashOf(kindSha384, fill(112, 0x61 as uint8)).encodeHex() == "187d4e07cb306103c69967bf544d0dfbe9042577599c73c330abc0cb64c61236d5ed565ee19119d8c31779a38f791fcd";
	assert hashOf(kindSha384, fill(127, 0x61 as uint8)).encodeHex() == "9bd06b1763c2cf7aef40e795dc65bc96d59c41b537f3ad72ebdefd485476b5717c1aeb37c327fe9c1831b12b9efd08ae";
	assert hashOf(kindSha384, fill(128, 0x61 as uint8)).encodeHex() == "edb12730a366098b3b2beac75a3bef1b0969b15c48e2163c23d96994f8d1bef760c7e27f3c464d3829f56c0d53808b0b";
	assert hashOf(kindSha384, fill(129, 0x61 as uint8)).encodeHex() == "39b6f5a7b0e781dbc419f72e49b30eaac10f2c98c4403bc610da31067fd1b48f324138c8615d2b496d08d73d5e865326";
}

test "sha512 padding boundaries 127/129" {
	assert hashOf(kindSha512, fill(127, 0x61 as uint8)).encodeHex() == "828613968b501dc00a97e08c73b118aa8876c26b8aac93df128502ab360f91bab50a51e088769a5c1eff4782ace147dce3642554199876374291f5d921629502";
	assert hashOf(kindSha512, fill(129, 0x61 as uint8)).encodeHex() == "4f681e0bd53cda4b5a2041cc8a06f2eabde44fb16c951fbd5b87702f07aeab611565b19c47fde30587177ebb852e3971bbd8d3fd30da18d71037dfbd98420429";
}

test "sha224 byte-wise streaming 200 bytes" {
	const h = newHash(kindSha224);
	for (let i = 0; i < 200; i++) updateHash(h, fill(1, 0x61 as uint8));
	assert finishHash(h).encodeHex() == "2559984fd15e055f0d84c346483508242f02653ab7956401e551511c";
}

test "sha256 byte-wise streaming 200 bytes" {
	const h = newHash(kindSha256);
	for (let i = 0; i < 200; i++) updateHash(h, fill(1, 0x61 as uint8));
	assert finishHash(h).encodeHex() == "c2a908d98f5df987ade41b5fce213067efbcc21ef2240212a41e54b5e7c28ae5";
}

test "sha384 byte-wise streaming 200 bytes" {
	const h = newHash(kindSha384);
	for (let i = 0; i < 200; i++) updateHash(h, fill(1, 0x61 as uint8));
	assert finishHash(h).encodeHex() == "0691b6e978614b67d60557b2a2cddd53406508522efa21c624dbbfa8ab6e726d5c586b489c7c09f24109a64c10211d48";
}

test "sha512 byte-wise streaming 200 bytes" {
	const h = newHash(kindSha512);
	for (let i = 0; i < 200; i++) updateHash(h, fill(1, 0x61 as uint8));
	assert finishHash(h).encodeHex() == "4b11459c33f52a22ee8236782714c150a3b2c60994e9acee17fe68947a3e6789f31e7668394592da7bef827cddca88c4e6f86e4df7ed1ae6cba71f3e98faee9f";
}
