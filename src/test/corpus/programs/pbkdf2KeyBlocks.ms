// pbkdf2 keyed from precomputed ipad/opad states matches an independent implementation (Python hashlib) for every digest
// at the key lengths that change the key block: empty, exactly one block, one byte over (hashed first), two output blocks.
//
// @stdout: pbkdf2 key blocks 30 checked, 0 wrong
// @exit: 0
// @skip-js: std/crypto has only a C backend (index.cms over runtime/crypto); there is no index.jms
// @skip-raiser: std/crypto has only a C backend (index.cms over runtime/crypto); there is no raiser random

import { pbkdf2, toHex } from "std/crypto";

let checked = 0;
let wrong = 0;

function check(digest: string, passwordLength: int32, expected: string): void {
	const r = pbkdf2("p".repeat(passwordLength), "salt", 3, 40, digest);
	checked++;
	if (!r.ok || toHex(r.value) != expected) {
		wrong++;
		console.log(`wrong ${digest} ${passwordLength}`);
	}
}

	check("sha256",0,"5ddf839afa2d5fb4be56e1a0f48917617559bef61ec122bfca1c7f75ac8f401d060b470b70403497");
	check("sha256",64,"a7eb20b4477a4cc9647a8343af3aa4465322d894a481e92a16da5e0ae37ad3d38bf986bed2adf051");
	check("sha256",65,"9f1b4cba4b646ed9a5d20a3cfa7ef757b162f7073a4578d7e93864f7d91e146f6c39db843799650c");
	check("sha512",0,"35728858479af699c1690e989eba0d104c6c9d7ff67373a48e4f87e90cb55af771ac93458ee4ba4a");
	check("sha512",128,"ae9967296ba9f3ff05582b4a78e59c1bb1bf135aa82f6959b03fd5e61f8deb71a6e31aba4a51d857");
	check("sha512",129,"fc17be54909918c01aac2de22ea457327fdc0b70b730cef9ce4904a1579467dc87584ddbfccf5c9f");
	check("sha384",0,"e6d0cf8b47c689cdbd07dd4b8bff90ec12a45093dbbd75fc757f0ded3138cbffaa94db103ced88f8");
	check("sha384",128,"d722da131b0d47e9db0f8189dcb4e1d4d3f83a307a75342f99e0d4c9106f9f0319da2312db0ab9bf");
	check("sha384",129,"e6ecc17ac009f461bbbefe144ae1686f677eac5fe9e10016a2e954d891e5affaaf900c022ddebdac");
	check("sha224",0,"f1b505d4ab9ab0a558170c9e5384ca52cf337b1af42e6c82a8fd622a83dde3f8b4b53f1c391ee4ec");
	check("sha224",64,"863386b35617ce5fe210f8af1382b9c82b1f1d43f8f7d71c36e01ca4fa016733acab887005f00510");
	check("sha224",65,"5237b08855dd8726d4a0a9ac5c7e625adaba233ae250a822b881c7aa6eb4905256da8d80665e91c1");
	check("sha1",0,"0cebfb1825d38ce91db4a69a0b9e776b2a2323eb4fcbcfdce402926cfc260d4848301644901249dc");
	check("sha1",64,"e3b09c012d7ef712e6d6fa000b358daea42ea4cc6487a5603760ffc290b0612bd4d2877e3703a138");
	check("sha1",65,"2831545255ebdfddea03e922dfe6b5ad3ce6b3f3194d4427b01cd2c359ce77689fd0190bb85f30fb");
	check("md5",0,"5de5f0cfe4c83116c2b557170fed8ca6431777640b1b838ff98fe1305e300e59556cfd7f653071d2");
	check("md5",64,"4fe21df4593706132f5e4333f27dfd494978b73440332c1250414d4de02e600e1101e7d8233c7cd8");
	check("md5",65,"5a055417f532d0e43dfdf628aace9c709a132603b732a739e80037b35508974d5a1ac220af4152c1");
	check("sha3-224",0,"347fcbf491aac11b87ae9f41f97766f0a7610e385a91eb85cef2e3fa55428c1a1ab78ed2e08dc8ae");
	check("sha3-224",144,"54782ccba62d06246fe3d497bb21a9bc929f113f8307ee1a865d8b420a12373c6fad9455734e2c87");
	check("sha3-224",145,"4e4aa820a2fc91266e0440a1e282ac1c6520cca5b89995c28f255ae5dd95c9f4b52022a35dd6b3b8");
	check("sha3-256",0,"14f7c2667e172280ff52c0464d67393e7549945efd165e9e87d9e270ff2ef959cae67e83edb5cc0c");
	check("sha3-256",136,"7a17fec664cb65bddee9f14b5bb26ecee3effe321813d3cfea1e3f62174aedbc9b79834de190fd62");
	check("sha3-256",137,"28df15ff6a188cf28406d43e7dd6874ac854099a338889d71cc75620a37ec021aa72ff69cf8369d8");
	check("sha3-384",0,"7140c428ad2c8435a4aec71f4b9f0d8416487a180539636c8ade4fadc976f40bf760d0292a1a82e7");
	check("sha3-384",104,"7d6e0469372866e4863a28cebe687da9f217bc08806f799f62452fe6178faf2c1ed5f8f53900acca");
	check("sha3-384",105,"51951c0f68a2dc838740372e0ef3ec2565ea362ed9031e3244fb55bbe1a8e2dc66f3a37c5e5e78f6");
	check("sha3-512",0,"e213b7c9e15c5f546f581e1a5f278fd2dc48504b1144ea42de09a2f1da310a8d4581d5cf2dd6a652");
	check("sha3-512",72,"963dc34e942d507dac255ae226f796cdc712f0a52ca9d244c0f528af853a8c80396edb79b2ca9246");
	check("sha3-512",73,"e74b5ba15b10c324b963d148144b740027bdb2c5197df6a0b1d2a586fd011b23797ed8052194327d");

console.log(`pbkdf2 key blocks ${checked} checked, ${wrong} wrong`);
