import {
	EcPrivateKey, EcPublicKey, ecdsaSignSync, ecdsaVerifySync, ecdhSync,
	ecdsaSign, ecdsaVerify, ecdh, EcCurve,
} from "./ecNative";
import { ecdsaDerToRaw } from "./weierstrass";
import { CryptoError } from "../errors";

// Fixtures: OpenSSL 4.0.3 `genpkey`, `pkey -pubout`, `ec` (SEC1), `pkeyutl -derive` and
// `dgst -sign`; the rfc keys are RFC 6979 A.2.5 and A.2.6, their signatures cross-checked
// with `dgst -sigopt nonce-type:1`.
const aP256Pem = `-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgP1PMVHF46Oh5CNyU
+tRSrTVVBvgKkt8GcNhnH8ws81WhRANCAATHvNlDPSol9h+ppYbhznjRrOeGFnil
axmYMp4MCR5fweQTFRNcLX+L8ge39H0EbQoPZJjVGZLxEUA89vMKI3zU
-----END PRIVATE KEY-----
`;
const aP256sec1Pem = `-----BEGIN EC PRIVATE KEY-----
MHcCAQEEID9TzFRxeOjoeQjclPrUUq01VQb4CpLfBnDYZx/MLPNVoAoGCCqGSM49
AwEHoUQDQgAEx7zZQz0qJfYfqaWG4c540aznhhZ4pWsZmDKeDAkeX8HkExUTXC1/
i/IHt/R9BG0KD2SY1RmS8RFAPPbzCiN81A==
-----END EC PRIVATE KEY-----
`;
const bP256Pem = `-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgV9cOzHCCAZcCcx7O
6ug5jdO3G4RGQdhjar9lPGsfdAuhRANCAASWwkeaY8ctm6d4dhkeSc3ivfkI+Qj9
Izb456O7lc/2hwYEfHjnoPcXCcFBapX0Y7DiWf7ahTWQDPNRvehGEz19
-----END PRIVATE KEY-----
`;
const aP384Pem = `-----BEGIN PRIVATE KEY-----
MIG2AgEAMBAGByqGSM49AgEGBSuBBAAiBIGeMIGbAgEBBDAwj2q9XHcwnxew0X2B
hAa3YzQvzZVVX+fFxJjqKLTDiIL+v5v9D+VWDXkJOB4qoa2hZANiAASQEmrGNqB0
IaChK+zdkPGe/2mA1AGsuyKggI3DwkKV2xZvVaaXIN8G+zwcf551AewLlHB2YQWz
JX1AUTbp6j+NWHE7jRsxTC0lGiwJ5PX1LI2CZ4UnSClMl2bGhlhIoEE=
-----END PRIVATE KEY-----
`;
const bP384Pem = `-----BEGIN PRIVATE KEY-----
MIG2AgEAMBAGByqGSM49AgEGBSuBBAAiBIGeMIGbAgEBBDBS4RnzL3sE9LI0oTL3
pAAKm5rekFsWoifIE58jf0/331yDZntZFIckErmwjFRpZnChZANiAASli0Zqk1Qn
K69X2qvfgIEv8m5o8zgAA5wE/JeKAf+KKOcqRbZvVuU5Y34NrvaUrlYy/xBQ6x5u
xMELgvsylQQiviESuwAu90F1Wco0kqMfU5tQLD07BYjdKhCScaRQFac=
-----END PRIVATE KEY-----
`;
const aP256pubPem = `-----BEGIN PUBLIC KEY-----
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEx7zZQz0qJfYfqaWG4c540aznhhZ4
pWsZmDKeDAkeX8HkExUTXC1/i/IHt/R9BG0KD2SY1RmS8RFAPPbzCiN81A==
-----END PUBLIC KEY-----
`;
const bP256pubPem = `-----BEGIN PUBLIC KEY-----
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAElsJHmmPHLZuneHYZHknN4r35CPkI
/SM2+Oeju5XP9ocGBHx456D3FwnBQWqV9GOw4ln+2oU1kAzzUb3oRhM9fQ==
-----END PUBLIC KEY-----
`;
const aP384pubPem = `-----BEGIN PUBLIC KEY-----
MHYwEAYHKoZIzj0CAQYFK4EEACIDYgAEkBJqxjagdCGgoSvs3ZDxnv9pgNQBrLsi
oICNw8JCldsWb1WmlyDfBvs8HH+edQHsC5RwdmEFsyV9QFE26eo/jVhxO40bMUwt
JRosCeT19SyNgmeFJ0gpTJdmxoZYSKBB
-----END PUBLIC KEY-----
`;
const bP384pubPem = `-----BEGIN PUBLIC KEY-----
MHYwEAYHKoZIzj0CAQYFK4EEACIDYgAEpYtGapNUJyuvV9qr34CBL/JuaPM4AAOc
BPyXigH/iijnKkW2b1blOWN+Da72lK5WMv8QUOsebsTBC4L7MpUEIr4hErsALvdB
dVnKNJKjH1ObUCw9OwWI3SoQknGkUBWn
-----END PUBLIC KEY-----
`;
const badP256pubPem = `-----BEGIN PUBLIC KEY-----
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEx7zZQz0qJfYfqaWG4c540aznhhZ4
pWsZmDKeDAkeX8HkExUTXC1/i/IHt/R9BG0KD2SY1RmS8RFAPPbzCiN81Q==
-----END PUBLIC KEY-----
`;
const rfcP256Pem = `-----BEGIN EC PRIVATE KEY-----
MHcCAQEEIMmvqdhFunUWa1whV2ex1pNOUMPbNuibEnuKYisSD2choAoGCCqGSM49
AwEHoUQDQgAEYP7UuiVanTHJYet0xjVtaMBJuJI7Yfps5mliLmDyn7Z5A/4QCLi8
maQa6elWKLxk8vGyDC1+n1F3o8KU1EYimQ==
-----END EC PRIVATE KEY-----
`;
const rfcP384Pem = `-----BEGIN EC PRIVATE KEY-----
MIGkAgEBBDBrnT2tLhuMHAWxmHW2ZZ9N4jw7Znvyl7qapHdAeHE32JbVck5McKgl
+HLJ6mDS7fWgBwYFK4EEACKhZANiAATsOk5BW04ZpFaGGAKfQn+l2pqLxK6S4C4G
quUoazAMZN748OqQVYZgZKJUUVSAvBOAFdm3LX1XJE6o75rAxiGJZwilk2f537n1
TKhLPxydsSiLIxw64NT+c0T9JTMmRyA=
-----END EC PRIVATE KEY-----
`;

function got<T>(result: Result<T, CryptoError>): T {
	if (!result.ok) throw new Error(result.error.message);
	return result.value;
}

function rawHex(der: Readonly<uint8[]>, size: int32): string {
	const raw = ecdsaDerToRaw(der, size);
	if (raw == null) throw new Error("not a DER ECDSA signature");
	return raw.encodeHex();
}

test "p256 RFC 6979 A.2.5: public point and deterministic signatures" {
	const key = got(EcPrivateKey.importPemSync(rfcP256Pem));
	assert key.curve == "p256";
	assert got(key.publicKey().exportPemSync()) == `-----BEGIN PUBLIC KEY-----
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEYP7UuiVanTHJYet0xjVtaMBJuJI7
Yfps5mliLmDyn7Z5A/4QCLi8maQa6elWKLxk8vGyDC1+n1F3o8KU1EYimQ==
-----END PUBLIC KEY-----
`;
	const sample = got(ecdsaSignSync(key, "sample", "sha256"));
	assert rawHex(sample, 32) == "efd48b2aacb6a8fd1140dd9cd45e81d69d2c877b56aaf991c34d0ea84eaf3716f7cb1c942d657c41d436c7a1b6e29f65f3e900dbb9aff4064dc4ab2f843acda8";
	const test256 = got(ecdsaSignSync(key, "test", "sha256"));
	assert rawHex(test256, 32) == "f1abb023518351cd71d881567b1ea663ed3efcf6c5132b354f28d3b0b7d38367019f4113742a2b14bd25926b49c649155f267e60d3814b4c0cc84250e46f0083";
	const sample512 = got(ecdsaSignSync(key, "sample", "sha512"));
	assert rawHex(sample512, 32) == "8496a60b5e9b47c825488827e0495b0e3fa109ec4568fd3f8d1097678eb97f002362ab1adbe2b8adf9cb9edab740ea6049c028114f2460f96554f61fae3302fe";
	const pub = key.publicKey();
	assert ecdsaVerifySync(pub, "sample", sample, "sha256");
	assert ecdsaVerifySync(pub, "sample", sample512, "sha512");
	assert !ecdsaVerifySync(pub, "sample", sample512, "sha256");
}

test "p384 RFC 6979 A.2.6: public point and deterministic signatures" {
	const key = got(EcPrivateKey.importPemSync(rfcP384Pem));
	assert key.curve == "p384";
	assert got(key.publicKey().exportPemSync()) == `-----BEGIN PUBLIC KEY-----
MHYwEAYHKoZIzj0CAQYFK4EEACIDYgAE7DpOQVtOGaRWhhgCn0J/pdqai8SukuAu
BqrlKGswDGTe+PDqkFWGYGSiVFFUgLwTgBXZty19VyROqO+awMYhiWcIpZNn+d+5
9UyoSz8cnbEoiyMcOuDU/nNE/SUzJkcg
-----END PUBLIC KEY-----
`;
	const sample = got(ecdsaSignSync(key, "sample", "sha384"));
	assert rawHex(sample, 48) == "94edbb92a5ecb8aad4736e56c691916b3f88140666ce9fa73d64c4ea95ad133c81a648152e44acf96e36dd1e80fabe4699ef4aeb15f178cea1fe40db2603138f130e740a19624526203b6351d0a3a94fa329c145786e679e7b82c71a38628ac8";
	const test384 = got(ecdsaSignSync(key, "test", "sha384"));
	assert rawHex(test384, 48) == "8203b63d3c853e8d77227fb377bcf7b7b772e97892a80f36ab775d509d7a5feb0542a7f0812998da8f1dd3ca3cf023dbddd0760448d42d8a43af45af836fce4de8be06b485e9b61b827c2f13173923e06a739f040649a667bf3b828246baa5a5";
	const sample256 = got(ecdsaSignSync(key, "sample", "sha256"));
	assert rawHex(sample256, 48) == "21b13d1e013c7fa1392d03c5f99af8b30c570c6f98d4ea8e354b63a21d3daa33bde1e888e63355d92fa2b3c36d8fb2cdf3aa443fb107745bf4bd77cb3891674632068a10ca67e3d45db2266fa7d1feebefdc63eccd1ac42ec0cb8668a4fa0ab0";
	const sample512 = got(ecdsaSignSync(key, "sample", "sha512"));
	assert rawHex(sample512, 48) == "ed0959d5880ab2d869ae7f6c2915c6d60f96507f9cb3e047c0046861da4a799cfe30f35cc900056d7c99cd7882433709512c8cceee3890a84058ce1e22dbc2198f42323ce8aca9135329f03c068e5112dc7cc3ef3446defceb01a45c2667fdd5";
	assert ecdsaVerifySync(key.publicKey(), "test", test384, "sha384");
}

test "OpenSSL signatures verify; a tampered message, signature, hash or key does not" {
	const message = "the quick brown fox";
	const pub256 = got(EcPublicKey.importPemSync(aP256pubPem));
	const pub384 = got(EcPublicKey.importPemSync(aP384pubPem));
	const sig256 = "30460221008f443fc09bc04eaef69455dd6191ae8cd9400ad8d6eef89979d93c563dcf7802022100e1408e9fe6afc214d8fd51a7b2b1caeb05e14d3ac2314defa0295ffc5e9979e7".decodeHex();
	const sig256x512 = "3046022100d4c6572eeb07ab6c3c99b66f37b8eeb0fb5dec36ea52fa0462975d6712c6cc29022100ea216462363576f84698c6915342cab20a612be74cd37ff3c3dda7affd79a610".decodeHex();
	const sig384 = "306502304af3cc5426682f0b9c2cd7e285230f610192a8ee80f322aa03732bd2a6a526fc41b174f83f2042ec524de778cec506b7023100c0b6b0eaae1b33c23f1722c11608f3fc9e423bedff46eb25078625b0f6f13d649bf68fc3416ceaf682416f82038bdccf".decodeHex();
	const sig384x256 = "30650230111b188e18a8f267c71b809e26ed3e4a3585487609c4f43e5cc15db4317e34f89920bb63873d9ef97f650c46e66a6c83023100ee6719b03252f486b34cfc862e57fe15a046c7120080e48da869760e44ec37b9cc7530439d9e2e14a8048a3986ec1557".decodeHex();
	assert ecdsaVerifySync(pub256, message, sig256, "sha256");
	assert ecdsaVerifySync(pub256, message, sig256x512, "sha512");
	assert ecdsaVerifySync(pub384, message, sig384, "sha384");
	assert ecdsaVerifySync(pub384, message, sig384x256, "sha256");
	assert !ecdsaVerifySync(pub256, "the quick brown fix", sig256, "sha256");
	assert !ecdsaVerifySync(pub256, message, sig256, "sha384");
	assert !ecdsaVerifySync(pub256, message, sig256, "md5");
	assert !ecdsaVerifySync(got(EcPublicKey.importPemSync(bP256pubPem)), message, sig256, "sha256");
	assert !ecdsaVerifySync(pub384, message, sig256, "sha256");
	const bent = sig256.slice(0);
	bent[40] = (bent[40] ^ 1) as uint8;
	assert !ecdsaVerifySync(pub256, message, bent, "sha256");
	const cut = sig256.slice(0, sig256.length - 1);
	assert !ecdsaVerifySync(pub256, message, cut, "sha256");
	assert !ecdsaVerifySync(pub256, message, [], "sha256");
}

test "ECDH matches the OpenSSL shared secret both ways on p256 and p384" {
	const a256 = got(EcPrivateKey.importPemSync(aP256Pem));
	const b256 = got(EcPrivateKey.importPemSync(bP256Pem));
	const want256 = "a0dacf17080adb2105cfcc5996ec442749133bc787e81f5f923b16a4b9b70ef0";
	assert got(ecdhSync(a256, got(EcPublicKey.importPemSync(bP256pubPem)))).encodeHex() == want256;
	assert got(ecdhSync(b256, a256.publicKey())).encodeHex() == want256;
	const a384 = got(EcPrivateKey.importPemSync(aP384Pem));
	const b384 = got(EcPrivateKey.importPemSync(bP384Pem));
	const want384 = "fb28e0a52b1b8ef847eeea826825a35c415e40572fdb1e56735b229e9380b1b5eff823d886652e345d71a6cb8c66cc17";
	assert got(ecdhSync(a384, got(EcPublicKey.importPemSync(bP384pubPem)))).encodeHex() == want384;
	assert got(ecdhSync(b384, a384.publicKey())).encodeHex() == want384;
	assert !ecdhSync(a256, b384.publicKey()).ok;
}

test "a public point off the curve is refused at import" {
	assert !EcPublicKey.importPemSync(badP256pubPem).ok;
	assert !EcPublicKey.importPemSync(aP256Pem).ok;
	assert !EcPrivateKey.importPemSync(aP256pubPem).ok;
	assert !EcPublicKey.importPemSync("not a pem").ok;
}

test "PKCS#8 and SEC1 forms are one key, and export matches OpenSSL" {
	const pkcs8 = got(EcPrivateKey.importPemSync(aP256Pem));
	const sec1 = got(EcPrivateKey.importPemSync(aP256sec1Pem));
	assert got(pkcs8.exportPemSync()) == aP256sec1Pem;
	assert got(pkcs8.publicKey().exportPemSync()) == aP256pubPem;
	assert got(ecdsaSignSync(pkcs8, "m")).encodeHex() == got(ecdsaSignSync(sec1, "m")).encodeHex();
	assert got(got(EcPublicKey.importPemSync(aP384pubPem)).exportPemSync()) == aP384pubPem;
}

test "sha1 and unknown hashes are refused for signing" {
	const key = got(EcPrivateKey.importPemSync(aP256Pem));
	assert !ecdsaSignSync(key, "m", "sha1").ok;
	assert !ecdsaSignSync(key, "m", "md5").ok;
	assert !ecdsaSignSync(key, "m", "sha224").ok;
	assert !ecdsaSignSync(key, "m", "nope").ok;
}

test "generated keys sign, verify and agree on both curves" {
	const both: EcCurve[] = ["p256", "p384"];
	for (const curve of both) {
		const a = got(EcPrivateKey.generateSync(curve));
		const b = got(EcPrivateKey.generateSync(curve));
		assert a.curve == curve;
		const sig = got(ecdsaSignSync(a, "hello", "sha384"));
		assert ecdsaVerifySync(a.publicKey(), "hello", sig, "sha384");
		assert !ecdsaVerifySync(b.publicKey(), "hello", sig, "sha384");
		const ab = got(ecdhSync(a, b.publicKey())).encodeHex();
		assert ab == got(ecdhSync(b, a.publicKey())).encodeHex();
		const again = got(EcPrivateKey.importPemSync(got(a.exportPemSync())));
		assert got(again.publicKey().exportPemSync()) == got(a.publicKey().exportPemSync());
	}
}

test "async forms give the sync results" {
	const key = got(await EcPrivateKey.importPem(rfcP256Pem));
	const sig = got(await ecdsaSign(key, "sample"));
	assert rawHex(sig, 32) == "efd48b2aacb6a8fd1140dd9cd45e81d69d2c877b56aaf991c34d0ea84eaf3716f7cb1c942d657c41d436c7a1b6e29f65f3e900dbb9aff4064dc4ab2f843acda8";
	assert await ecdsaVerify(key.publicKey(), "sample", sig);
	const peer = got(await EcPublicKey.importPem(bP256pubPem));
	const a = got(EcPrivateKey.importPemSync(aP256Pem));
	assert got(await ecdh(a, peer)).encodeHex() == "a0dacf17080adb2105cfcc5996ec442749133bc787e81f5f923b16a4b9b70ef0";
}
