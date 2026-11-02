// XChaCha20-Poly1305 across the block boundaries of the vectorised ChaCha20 (64 and 256 bytes) and
// the Poly1305 padding (16 bytes). Each constant below was sealed by Monocypher's crypto_aead_lock with a
// fixed nonce, a plaintext of byte i = i * 7 + 3 and an AAD of byte i = i * 11 + 1 that is length % 19 bytes
// long, so opening it proves the bytes match the reference construction. Every length also round trips
// through seal, and a flipped tag bit or body bit is refused.
//
// @stdout: opened 12 of 12 plain text exact 12 of 12
// @stdout: round trips 12 of 12 flipped tag refused 12 of 12 flipped body refused 12 of 12
// @exit: 0
// @skip-raiser: std/crypto/chacha20 has only a C backend (index.cms over Monocypher); there is no chacha20.rms

import { Buffer } from "std/core/buffer";
import { ChaChaKey, seal, open } from "std/crypto/chacha20";

const KEY_HEX = "202326292c2f3235383b3e4144474a4d505356595c5f6265686b6e7174777a7d";

const BLOBS: [int32, string][] = [
	[0, "404142434445464748494a4b4c4d4e4f50515253545556579bf3874303c5345dc5bb9fc9619531dc"],
	[1, "4142434445464748494a4b4c4d4e4f505152535455565758400b62a2f0fa202add5afd197b51069382"],
	[15, "42434445464748494a4b4c4d4e4f50515253545556575859c3cbbe4110aa6be5bc4c1dfb4a1b8f45cd9dcec05c6e15524327004c0c7f6f"],
	[16, "434445464748494a4b4c4d4e4f505152535455565758595a5e68c888916541e78d47f14b84bba9101a2002c6c0914b790a34ae1a34ef92ef"],
	[17, "4445464748494a4b4c4d4e4f505152535455565758595a5b3a6941360d75eaea7a773e49cbfa2f76775fdfcd33713177e622d9933b439f6d2d"],
	[63, "45464748494a4b4c4d4e4f505152535455565758595a5b5cebee3ace89e4254930d1e7cbd56a887dfd175c28c70f5b593a1dea1d1f1cff9a58ccebe1ef4174f159f55b41f09ef86d14fecc29f9122a12487fa0e5fe05f5aad46a4df07fcf1c696fb4b351a1cba2"],
	[64, "464748494a4b4c4d4e4f505152535455565758595a5b5c5dac28b922603e47c310709606232739708d72183c3736e04e16ddd2c8eaf976d8a6a3955eb9c7e3c82b6ba1ce97f53186887bd26770eb06eef988808eb897e13d72bea18e728e53fc418759f16d4dec07"],
	[65, "4748494a4b4c4d4e4f505152535455565758595a5b5c5d5ecb75bec51d5a0fddf2b7506abfd6af1a030cb8968b70f8a174a617bce878d508ea7b4fa2108eface953fc782427522a60c6bf1337f9731de66f27f0e2c1296bbfd30ed7172aa5daadfdd2baa89c615f47f"],
	[255, "48494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f81f21c9e839ef11c84b57daf8ad40d175b65840b6ad79b7cfbdf8ae2658a39f10f460cd1a5bd916978af8888f2bd7f688a274b4077bf5da36c5583e4522a83557ad307ff33d6d67ffc9dfd3186af604b1286976ab308d8706a57b4b3b841c1cbe89dc9c200f83ccb8e6539a0f1fb78b3ea9371a0c4b7b74d824b964c8a0d19c9d59f2c6a604f3632939bf2b15157535aa008444e86da8aaadc0dabba341d3785089f0f57ea319585932514af5c8fb866c8e41e1de4ce2fc2064b8eb9396df7ca78eb2db71849528c78f81e1f3ebcf35d3db8762456c8a992b75270a2c7915e780f31909bacabc7e312538622463c4390d4e37639d0253b316cd95bba1a5967a4d003c1e3d0394ca53c4ce5c9ae1c0c"],
	[256, "494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f6078a87488ad2a25746bbd564ead9a5a02b22b5c275834dbe36057968539cb8e7ef8daadf6d725665bea136e2c7bef896e4e802ac9b4f0d98a7a244cd9f424dacaf512a549f664cfcf3edb76559a4581303debaeeaea5036406e014eaffc60c4370bdb767f59686c263354761e647b384c9667e38be07d7b500e327444694be5e953553f829c126ec59359e7b30d9a49c0f679650a9662bca5257bdbd1bb3c25a38cf9454156dd9f0984b53fa84b65e5ef838af0d49f0ac334cb0434cdc54c780ddbef5c44a1898d736c202acbd3502715fdeca4faf4d0e9c6d6cafa314b4b3d1be287c973e99db54f1c6d67e3010211fc884422a15fc5b18162b5877aeb1356941d0c1fe0277d07e05b1dc68f3669dc0f"],
	[257, "4a4b4c4d4e4f505152535455565758595a5b5c5d5e5f6061e2a8813fbc2419fa67b62c0882e901195aba22f9c1e0ef39ef3732370514b3685ed3463da9ee665845c7c88b9826fde32de91de7118abac91c2f781dd304cda93127c6a45a996b37bbf2297f37dce6e5bdead1cde86f9117264bb6b0846ad3453fb6edcb8aa4808e82f192c33d75f745e6a1759132b60f5f831d5806200f4ba1124306e1351178e3f55d696c9ce6b25ccd5626acbabaa612ad72459364066dea1de28c3638102c2f227fee8b2b2f10bc2fb63e023e3523ad281f3238c34fd726cf414811487c17b148fc360611dfbc09db47612485cb5e2e7eb82c5fd55daf4e620bca148be52835d46cf8112bf4b3b23fc0e954f6bb909681d45259ad3bf48a5d8162f4b1b2ffb0e6888d58a7db26e427"],
	[1025, "4b4c4d4e4f505152535455565758595a5b5c5d5e5f606162a0fe9528b3441e6837b02af470880cc77e22eade999f6802cea7add9bd54d1ea99c5fde9d2b10cd42b5e5c51c8a3fe6003d78cfa08f24abec20e4bf2c1c6391cdc0002be3925025a8f9be05949945e1ea4e6b385f5ac3ca0b7a4282bb564502e95147e7a5484f86beb9e1987c81528994d43c047985d44edd907ed01027349a2500b0ac30cd5074069509ce9ea59a866fbde70119d0d2d39ece62410454700fa1776a2b8a7fb05c5b161aae858060d8a4d9a7f1c1f12aa56d14831083aa7650f18453119f535ba0dffee11ecf09920c442d75258a21b590adaa727f91f1258597c7bdfa31ad681cfc01295328caa0669f60dccde34fcac5b703d5c35c455d712f6cb3fa7e49eac61d0013195dd843b1e38d92c02c15a7748c1e99c575018e901a5bccf1e0ca83c918c6d3413d9ae50a5fb49414a55ed9aa71857e6f8cb8c1cfe135a503afdd8cb22d8854cafabdb10e9f99c6e363b9d8583f9cfc2176c4c5568b7de334802847ae3c2c148357406a924d701bcff4238390f5e6c10a723a8bc97940fff45e18b473667900564ada81fe94e5ec5fa89bea4f28570280392e609f9e34cfefef51780e9c1fd1cddfeaa0a781c82d3bf862750ad1d4ca02c22b3738265e050470ad0e4da4c2ab7347d34c94a6b15fe2751c506ee3782f3f426693a1fef8fc5f6b7536b3f96cd57d3c9d0321d8612cb35a40175e8b79a01136ee83005041df2fc38d6f4d04fbaa6e5da5c78c3221355c3eb28d675dcbb6ec190b0af4bab61c147df65708e0ebfd72a9430211bebfa93b6f2c6a2959c405ff2afb246fa1b745f2f06d712c15f931ad923ede7328b155b1b005418e4edde466f3797a2983dee404d2e621a2b7b978f04d3b9f57c76ae515adc61efd7fc13b47741c0dd194f22cd0f9057b6dcd57a4c12ac724d93e2ad00a6a38c86623f14bcac600528572d476b6e73f708b5f50bc9f3c543c41fd454deab8c9de3c00c23e140ffcd674d3698bcc5328c821c75e2d2fabf73a6ecbe1a8c09db86fc887a5bb65f1b6bb3922279c272eaecb064b3e5eec063b339760f338c7a216ecbd8942537148647e1187d0882d127ca078211ca1a94f0b65ef63cfbe527dba8126a37e176e70b1a66b7ea28b72309ab1204b6826957efca93fc72a74de4d2dff8d1a8c94508cbe3211b54a87d4e9e563e3bbf53f0671afe1e481be1d0520141f59fd16011b6c66570ffa0023a90069e556c75d1b42ad6dfc98557d70e10f15817dcd8da4ab4681123f24db30ee661388532f58801a649c7432455b3e51bee0ae768ae98e35afafb016e45b5c1683c12d4b45729670217d298418fb93c7b1a470713db0701b4fafc1571b19565675417d7ba76623d71f487bcc08dfa10213148020eff6709edb44e1437093c53cf8218995f7c63c25d27308d9f381fbc26e56fba309c82688d44c2deb7a7d46665e8169063e6a973faa8da7cc0be"],
];

function pattern(length: int32, mul: int32, add: int32): Buffer {
	const buf = Buffer.alloc(length);
	for (let i = 0; i < length; i++) buf[i] = ((i * mul + add) & 255) as uint8;
	return buf;
}

function flip(blob: Buffer, index: int32): Buffer {
	const copy = Buffer.copy(blob);
	copy[index] = (copy[index] ^ 1) as uint8;
	return copy;
}

const imported = ChaChaKey.import(Buffer.fromString(KEY_HEX, "hex"));
if (!imported.ok) throw new Error("import failed");
const key = imported.value;

let opened = 0;
let exact = 0;
let trips = 0;
let tagRefused = 0;
let bodyRefused = 0;
for (const [length, hex] of BLOBS) {
	const aad = pattern(length % 19, 11, 1);
	const plain = pattern(length, 7, 3);
	const blob = Buffer.fromString(hex, "hex");
	const result = await open(key, blob, aad);
	if (result.ok) {
		opened++;
		if (Buffer.compare(result.value, plain) == 0) exact++;
	}
	const sealed = await seal(key, plain, aad);
	if (sealed.ok) {
		const back = await open(key, sealed.value, aad);
		if (back.ok && Buffer.compare(back.value, plain) == 0 && sealed.value.length == length + 40) trips++;
	}
	if (!(await open(key, flip(blob, blob.length - 1), aad)).ok) tagRefused++;
	if (!(await open(key, flip(blob, length > 0 ? 24 : blob.length - 1), aad)).ok) bodyRefused++;
}
console.log(`opened ${opened} of ${BLOBS.length} plain text exact ${exact} of ${BLOBS.length}`);
console.log(`round trips ${trips} of ${BLOBS.length} flipped tag refused ${tagRefused} of ${BLOBS.length} flipped body refused ${bodyRefused} of ${BLOBS.length}`);
