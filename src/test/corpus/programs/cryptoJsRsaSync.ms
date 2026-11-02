// RSA *Sync forms agree with the async forms and with keys, signatures and ciphertexts made elsewhere: on the C backend
// the Sync form is the native one, on JS it is the BigInt code in std/crypto/pure/rsa. Verifying and decrypting the
// constants of cryptoJsRsaInterop (made by mbedTLS, WebCrypto and node:crypto) gives the same answers as the async
// forms, PKCS#1 v1.5 signing equals the deterministic constant, a signature or ciphertext made by a Sync form is
// accepted by the async forms, and a freshly generated Sync key signs, verifies and round trips through PEM.
//
// @stdout: sync pem private true public true
// @stdout: sync verify pkcs1 c true node true pss c true js true node true tampered false wrongHash false
// @stdout: sync sign pkcs1 equals constant true async accepts pkcs1 true pss true
// @stdout: sync oaep decrypt c true js true node true async decrypts sync ciphertext true
// @stdout: sync generated key signs true oaep true pem true
// @stdout: sync refusals sha1 true bits true weak key true
// @exit: 0
// @skip-raiser: std/crypto/rsa has a C and a JS backend and no rsa.rms

import { Buffer } from "std/core/buffer";
import {
	CryptoError, RsaPrivateKey, RsaPublicKey, sign, verify, decrypt, encrypt, signSync, verifySync, encryptSync, decryptSync,
} from "std/crypto/rsa";
import { fromHex } from "std/crypto";

function bytes(hex: string): Buffer {
	const decoded = fromHex(hex);
	if (!decoded.ok) throw new Error("bad hex constant");
	return decoded.value;
}

function must<T>(result: Result<T, CryptoError>): T {
	if (!result.ok) throw new Error("crypto call failed");
	return result.value;
}

const rsaPem = `-----BEGIN RSA PRIVATE KEY-----
MIIEowIBAAKCAQEArYotbakvAndXP1PzQgKuRstEmgRdQbowe37Jk+C6WY1VqwvM
g4ZvKmMsq25f5oDQbv7soLlK+8o/qP0y9FKjROlTqdDR6KI9NOFeiSEmcGYDyV0+
klgcyJXLtvpsh+9MERHBi7q0lOS5sJCLoL0Zs/sbBFH79RqShhIeW7XA5ln6erz0
nd4PlF7tvw3AdK5G5DyE0W3Qsc1Jt4+Re9WmZgEhl7Ta8KnNtVaglBDBxWDHhx0g
OrlsFeqdL3rStklGfjckY6IGpuq3mlx9La0irjvIa8VPU0XYyBJDDSWVJCXQB/s7
yHHIs8AZLkBjFnwZ8riFWAIq1SJRnnzYeZvODQIDAQABAoIBABAG3Vgt0kIbjGq0
UZhsj/TIy/6fXY925whYtrwZ+ovPsjQ4RDx3W2fiPdtdN60dg2Jk16ymQCcN0CBG
tgB7a0mvdMMPnnsqFJYAJE9syNSDj2D25BL24T2jG+u7p+9L6c3/wkypwwinMQD9
8G85V5jYHXAiNC84M4T/Ql984yJC0MZyxDHxUHFG97RGs6znrKWmuQlnXUyvlVST
l3mrL5kEIAdHTWfavlQ/es9+qpWLWCNVI2dGesBKAo8/TiRjqpLj657SiTHIP32W
2gGISsfIs0dR/Wlwatr4gBnkvaiEnhq/HPo59hQhHdJC9iCUzTPCmQigkyuq3Huf
SdqPRxECgYEA8TChBwTbMe14IyVpNTg9CjLlaRIB1huQ7v2Y60rdyr4xKiFliZg5
BaouCwFj50APmubnOUbeMy49eccgsdxFpyfQ5/C42UDNPya6n5/heBywN9ik7Nuj
aJ6EZCWSm3pmLmHFJGjNiiFr3SLc3+VSIQRag0YZopaDM2dsGTDVsmUCgYEAuDIg
C8R4dIUcQUuRN2ZX654Z0A17+sEApvAmD7s6lzt11K1jGtGM7AnQKSr8c9DXNFZk
L47rp0Q7OAmXodkSEXjvTDcYzXTxR7ugssExxzM5gbpNjCy8CUfYOZ0zyNzv2Cd1
3XSJ5uMQoCT8wfVWpY/dLnNgTbInPkFlPFHBnokCgYAwJP7fwc5nZvmmOl+H6hP1
Jze4A4ouTQ5fRmvx+93ODK0Ptd7o2mP3h4LtW3evv4/d4d2iB01vdfl7h441Mr0M
otwGkHy1kUPnKTnzhxygt0lNvIcfaLBzv8C5pO5g7sva0lVh8TGmMwmu+LiSUNpW
EOJodePEGrtR1YE0fhUKKQKBgD/CqjEom4HKKhO4MtZ4iOq42bqZUFdmw/EFpEdB
ynBbVth+BJZd/2gdpX76sFTu7+/gD+IemRhXmCA3wdN2rrh5omxBjkZgurzYCDKY
icCozLlJYlqpiZW01vZqomhfgm7SigxUsP/JjhHBe/UwFgRNnoTbz3RVvRvhy0ds
DZfxAoGBALZ3NIaIeJgVctdYdOl8Tk44mmU9S4nmHpyZZetV+5VecsnjYjXHGV3E
XO4OJBrmfvco+R7uiflrTqVi6RFzRGabbT5m5j8rfWqphSc5C++/mgA3yMoazAzc
8ClJ7gQlQWNVIzMd0yMzYDDpOI/NFUm66gPP6Bo7CyXC2w/W4DI8
-----END RSA PRIVATE KEY-----
`;
const rsaPublicPem = `-----BEGIN PUBLIC KEY-----
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEArYotbakvAndXP1PzQgKu
RstEmgRdQbowe37Jk+C6WY1VqwvMg4ZvKmMsq25f5oDQbv7soLlK+8o/qP0y9FKj
ROlTqdDR6KI9NOFeiSEmcGYDyV0+klgcyJXLtvpsh+9MERHBi7q0lOS5sJCLoL0Z
s/sbBFH79RqShhIeW7XA5ln6erz0nd4PlF7tvw3AdK5G5DyE0W3Qsc1Jt4+Re9Wm
ZgEhl7Ta8KnNtVaglBDBxWDHhx0gOrlsFeqdL3rStklGfjckY6IGpuq3mlx9La0i
rjvIa8VPU0XYyBJDDSWVJCXQB/s7yHHIs8AZLkBjFnwZ8riFWAIq1SJRnnzYeZvO
DQIDAQAB
-----END PUBLIC KEY-----
`;
const rsaPkcs1Sig = "8725f31764d149614e11940b8ff5c379d56a49891d39c35bcad3aa641f7f2affbbfb0f52d29468145362d798f70f13afcab87de4523a25eac809b141f5e25332dc6ba394d1410477b272200805cf76c7398e20cc7dc6d53b73a194494dea5fe16f9813ef0e5b55b7481eba2c3c2fa34816210ff42af553da4745ddecc6d43ced6718786899407b992cfcb1b46ae5ca721a2bdd64722d187d8caab6116975a770d68278095a4a7fb334b8a70b361fc0bcdf17564a6269774116586dc9167efb7450b9723c2f85115f24cb81e641e571f11c998c5e79e1903e903f94c0e16f8e32666dc39be55258978401ee37396b0ad9ceb5c1158c4843000688311b41665e68";
const rsaPssSig = "77c7078fd964a7d2bf1c90cc047b560fa5dfe14499b6b04b5c7305798b2f184a6d545014a6e1c0c3544015f738fd85f46ea88c87361f4bb2eacc792153c9044900915769ab5cef4834814b4d1dab43e66f14a964f3fd1e7ce1c1734485f0639edea358e9803a816bf765a42efd4965e8afef67320734b822aa63f73138404d4a4c2927d440fc3559363ae55ef0bdd79224e6618b21cdfa59647dbac2af4a154e7e98c1b7d54132bfb01a0a02b7180b7989c6c6a4ca3d325cf404c6036c3f1ec75ecb6b0046130239971dfc71f7698224d8c3982037126ddcc3307ef3b1b69053fbabc145ca3b6794909353ced041f7a82f4c9f0363d2b449383085825c97ea82";
const rsaOaep = "831b6e5fbd060475b2e133736c907a56ce407a2a12318e9bf64ba9887ebfc60c86473e8d3b5e3a5f1693565e84fd8193a95c4952bbd07ba2d9ce98076f03acf61381ea165d6f02e253468bfd05270e88ccbe020292f86bf91cdddf92fc6eeef0410e3a567d5b38a38ab8d6d0da74b298734894699196fea65d8cb85a270b81299215474c5e430d82a410c148099f1d5f42d0e6af434c0a6b61c87cb6ffb1bd998d109e3f317e94197a76bb055d68da39b1774d38bc3dbf945ed2b215b2501bf55ff668d4a1a5b88da71cb0b3af07374041c03241fcd6d19e562fcbaaf87e551675882ab1b7d077bbaa2c4dba81f3cc223bace9b91443b7f841f79bb4ab7c1c20";
const jsRsaPssSig = "6bef65dc96e3d28ce96563983c6d48fbc1b90ce80a1993134b1a218a38228adf2c25be8132e70c26b48463cacaf855261ccc8d1b474b0ce6bef7a690c2ade5ab1340767675311409770063eaa33f3ea45a9bbccd2702b39efa09b19871ea5af7e9def80d18934adbc208a26d8f24e35f9a58a94b1c7f6167b1ee575d8d47192169061ef0d7646a0265298bee0a7fa66aea420c9b118d5934cdb7443005c74c638f7e35e681125144aaf4cbde25df98cab47f8ed81a2fe62ebf1a60bd8d2c6c76b1cfe6217af5a9ef952b688887526b05f609a47fa30aef068cf6739de65500335b01ad19e59b4eb50405a7db0068cbe914d521d2771a8228ac9aa70c0ecb0b85";
const jsRsaOaep = "82d4d130490b4b93bc6e6de998be93086da353dfa1d3c8b0bcd2adf1bc841ca051db014da818c534742c98051dfc3fa9c38d4b8d41747eb621e9c5490519ce9faa04e8cb0d1a4d8be310fc7a940c76c9a2b1a5f1ff0f880b1a9a6554653ed0a5a4c35f9641535d6c7ce9651124ea3e084a4c899cd87309510a5c0433d16c23f35866a5794c0e7a8bde5749f3454bc63ec5f638e3c8481f186d85a8a41f4b2e6763633bc3470c2b82facb03df22c487fae396f7dc4488214b4b536469043d5c602b80bac2bb68a7c3e3fa9ae79e42a2269dcb1732346c3bdef2fe9242192f139c030cdc59c4adb27ebd37b6f24b9a7f71265c1dea503ffb215b669ebd5d201aef";
const nodeRsaPkcs8Pem = `-----BEGIN PRIVATE KEY-----
MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQC88rvRoggwNc7d
tCYPvr90o9tJfCuvXnE1L5PEzPmqZg+6z6pHkLYq8ZyeNKVS2MVbqy4cS3VTaWZh
3PkzZ4sKulZGEZM9eYRrUJEFjf1gluKZJNinravyESGNW+Gt6CxGOS7N01YPJ0Bd
/FSiGRELw8276z6vw8PoCrjInNxL5rHYoqeZh0wR/rdMJhOvXsDitsafmzqIxWBp
2j890KGKsQIbmdS/tcAgvkMWa5OpPSYI78PVmxsczvtTLLzQRImfu/B1S3/ibY+g
ul4L75f9xtzIanlsPE5uXzXSFsbAUcAmWYEEMJiyzkeUYSQ0WkAYTi/bEKj4LJhn
qyLIYtR3AgMBAAECggEABpoG7+y7LOjXlBPbd8j29x25tEtijcHWyMBWmsivbHTp
opUafCrVNcWzu19X62YbHZHRWzgghRj1dJpI5rMWcfocUfecby7T7pmMOs2nba/r
HBiw4GLtoAtZlcI0R2Q8r8ag5c+3F3Gl13xqfjAya6vPgC8lXvTDEodu+Pg239WQ
2kFWcbOQZQ4xrUlJYSUKGbvauUxhYXKaVz+fXGpgPuWOIlJyJ31ftpcnTFy63JU2
Qk0epZzq0QlEKzzUHNIQoCBYL07+7D8ksVgnqrDA75KpMQLBbO5FjHdWUBLJNGTI
ZExljIr3dDYwEi+j3oxRc/sQqFATVcQt0RBjeyhjOQKBgQDdtCh6Gn2aiJZnVfEI
kaeNOU78Xnzzl56DXkfOuAdreNSkiq1Gcplze7Y5tBblF23Z+XlEgE7oojajemlN
hkZyhiP2irSzQSwzMLHQFgbE2nzqexf4riBhXQ80m+c1jqak+OpT8fyjNSAFSG2L
9hpX4k6LVqzo+Uillpd9zDhwkwKBgQDaLWZmfNLEOkET+7CCFx4H0RPBLnVWl0Qt
wljWywrDlApyMh6n+kwJqHHsgR4Nvl11H4UPP/hdunfrqEPJcG6UEjfcQtLsBMW9
Pyvh0/b0D13OYkHXMv8YV1tdsQsLZNRcruwp0DShTs81WmfzOjnqGbjp4WR7hko/
X2XS37GPDQKBgEzH/RC0pfVkAnrNR8nI7/c39sPuUWXnh61FdKcCEwfEdBh8MqBo
Rf65xJVdamRy5ceM39O6gBmPPE8HsPp5W2KEVGYpCYXfN1iPL7W6OyPn60Ul1lp4
q5wsp3x31e41dj9COZ1S/ETlvC44NEA5vkvbg4o8PWv+EYvPiK23kYBjAoGBAIzK
LUFHnW7ZNLOjgESCjHN43OmVhEyrcmig+FkrTzfkKVWFuDinkTfORi3bKDywMnjp
LSEpI6nAMbCVtaCg+Ap/MyLk0F1TuxKjWDrzYHIgFGWhDGHFW84mWSQ9oiXpHAzv
KCDXZY8OXzJLs7bGRScnECeEtiXsA6+fbQLGLTtlAoGAJZ7L95RoQUq80WdchQbs
LAm5PlfnWk+6W/X1DTqNgzn8brrArnDXyqM0/aIYOa4bjnwjg3TvftYHZIq1+JS+
6lGu0OH6g3WN0ZqxBRlPFr3KzJnQk2MwvDcDztnnLsuOrB9AAj6z9ncARotS8bk7
eJ4K/+dYZex27DgCSSlucFc=
-----END PRIVATE KEY-----
`;
const nodeRsaPublicPem = `-----BEGIN PUBLIC KEY-----
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAvPK70aIIMDXO3bQmD76/
dKPbSXwrr15xNS+TxMz5qmYPus+qR5C2KvGcnjSlUtjFW6suHEt1U2lmYdz5M2eL
CrpWRhGTPXmEa1CRBY39YJbimSTYp62r8hEhjVvhregsRjkuzdNWDydAXfxUohkR
C8PNu+s+r8PD6Aq4yJzcS+ax2KKnmYdMEf63TCYTr17A4rbGn5s6iMVgado/PdCh
irECG5nUv7XAIL5DFmuTqT0mCO/D1ZsbHM77Uyy80ESJn7vwdUt/4m2PoLpeC++X
/cbcyGp5bDxObl810hbGwFHAJlmBBDCYss5HlGEkNFpAGE4v2xCo+CyYZ6siyGLU
dwIDAQAB
-----END PUBLIC KEY-----
`;
const nodeRsaSig = "9764c90c68757039108367a4cc81a82c1c1c34e435d21a9666b4f772919b48490e00fcd9c0da1a9299cef8c2390140d6302a85aec426c6a4a26ce4aae75ab706227a592c6b57a2c291a7fe1661ee5ffd64c665fb077b616ac3f87fb6386716421031700c00cb1abefa65646ce7f6cd9faf151f0bb6ca7a0049e05d054741d6738d9b60e2ee6dbfa7deac5f065050000cb8f93d6a15a262231c4ae4a62cf899b97e13d23ec52622fb377df621c0c7496a30d59c7640cda52294c2030cb1344f36682c3ebf54157f94d61036bc0dc65c5397caadb309561368e8e6175226f1f6014077d7718e7d15594245a051931712a4e095f0b3b319bb358cd38c8566d7f708";
const nodeRsaPssSig = "2a3ffdeb175ce84a7c0cc50dedad40225898a52734c2aa86615aee7c94778ba8aa03b46f4423cfd36af845903596a2c13f1da1758fc5532edf969651dc4e3b0896d6585c47250dceea7f2266dc1c3c994d34bec9ad15ca25ca3eb2cb252731ef69252aeb69f99fd66e89a8c504e8be26609371e5f40c978ba91ad1bd8369d496d4d4aafc68ca9b12aa4ae09fd9fc2e9a98e5533342528911bea0db95f61e0d385429bec02bedc505fbd98e9af5a2388f217cdbf2c9e0b01b0c3f08ae5b0848e53a20bbe952257e6fefb38d7a9bf2618ecf645c4f2202d0cc4042a60d04621d483e5f6f0c30e4667b5228577be70932a5ee528864b2eb3682b9e4c32d359f83f3";
const nodeRsaOaep = "995cba6c4ad45f8904d30cbc0bbc48e164f1a0b7c8553a5dae2742d63596b9b6975b7e9d702d6de207969d438188b56b90f14ad2329807ec059a97eaf3034d6787b45fac8c6fccce3bfaa336e6e519e721fcf8110eac8419edc7a7f7d747ff13846b3e7af0faa8de0ad8d12b0adea4603e496feba7c660fa2cb98d83e2f679388549e17ff0117e29cc7e9c9421f31340829c4266352f0e49e0b4fe6f9b3d9af11df8d68ffe074ed4868334a77b72af9b964db4168ca983ee4f81f2b68b549cb77b0a8282805dde6fdea2b550883e0c72be480681f6a8fbf52f56ef8c114363694a22c2c949ff2fe65f5e05ac390220a0a690f8c89a43c2a84a914989507d24a6";
const rsaPublicPkcs1Pem = `-----BEGIN RSA PUBLIC KEY-----
MIIBCgKCAQEArYotbakvAndXP1PzQgKuRstEmgRdQbowe37Jk+C6WY1VqwvMg4Zv
KmMsq25f5oDQbv7soLlK+8o/qP0y9FKjROlTqdDR6KI9NOFeiSEmcGYDyV0+klgc
yJXLtvpsh+9MERHBi7q0lOS5sJCLoL0Zs/sbBFH79RqShhIeW7XA5ln6erz0nd4P
lF7tvw3AdK5G5DyE0W3Qsc1Jt4+Re9WmZgEhl7Ta8KnNtVaglBDBxWDHhx0gOrls
FeqdL3rStklGfjckY6IGpuq3mlx9La0irjvIa8VPU0XYyBJDDSWVJCXQB/s7yHHI
s8AZLkBjFnwZ8riFWAIq1SJRnnzYeZvODQIDAQAB
-----END RSA PUBLIC KEY-----
`;

const key = must(RsaPrivateKey.importPemSync(rsaPem));
const pub = key.publicKey();
console.log(`sync pem private ${must(key.exportPemSync()) == rsaPem} public ${must(pub.exportPemSync()) == rsaPublicPem}`);

const nodeKey = must(RsaPrivateKey.importPemSync(nodeRsaPkcs8Pem));
const nodePub = must(RsaPublicKey.importPemSync(nodeRsaPublicPem));

const flipped = bytes(rsaPkcs1Sig);
flipped[100] = (flipped[100] ^ 1) as uint8;
console.log(`sync verify pkcs1 c ${verifySync(pub, "abc", bytes(rsaPkcs1Sig))} node ${verifySync(nodePub, "abc", bytes(nodeRsaSig))} pss c ${verifySync(pub, "abc", bytes(rsaPssSig), "sha256", "pss")} js ${verifySync(pub, "abc", bytes(jsRsaPssSig), "sha256", "pss")} node ${verifySync(nodePub, "abc", bytes(nodeRsaPssSig), "sha256", "pss")} tampered ${verifySync(pub, "abc", flipped) || verifySync(pub, "abd", bytes(rsaPkcs1Sig))} wrongHash ${verifySync(pub, "abc", bytes(rsaPssSig), "sha384", "pss")}`);

const ownPkcs1 = must(signSync(key, "abc"));
const ownPss = must(signSync(key, "abc", "sha384", "pss"));
console.log(`sync sign pkcs1 equals constant ${Buffer.compare(ownPkcs1, bytes(rsaPkcs1Sig)) == 0} async accepts pkcs1 ${await verify(pub, "abc", ownPkcs1)} pss ${await verify(pub, "abc", ownPss, "sha384", "pss")}`);

function opens(owner: RsaPrivateKey, ciphertext: string, expected: string): boolean {
	const opened = decryptSync(owner, bytes(ciphertext));
	return opened.ok && opened.value.asString() == expected;
}
const sealed = must(encryptSync(pub, "from sync"));
const asyncOpened = await decrypt(key, sealed);
console.log(`sync oaep decrypt c ${opens(key, rsaOaep, "oaep from c")} js ${opens(key, jsRsaOaep, "oaep from js")} node ${opens(nodeKey, nodeRsaOaep, "oaep from node")} async decrypts sync ciphertext ${asyncOpened.ok && asyncOpened.value.asString() == "from sync"}`);

const generated = must(RsaPrivateKey.generateSync(2048));
const generatedSignature = must(signSync(generated, "generated"));
const generatedPem = must(generated.exportPemSync());
const reloaded = must(RsaPrivateKey.importPemSync(generatedPem));
const generatedSealed = must(await encrypt(generated.publicKey(), "round"));
const generatedOpened = decryptSync(reloaded, generatedSealed);
console.log(`sync generated key signs ${await verify(generated.publicKey(), "generated", generatedSignature)} oaep ${generatedOpened.ok && generatedOpened.value.asString() == "round"} pem ${must(reloaded.exportPemSync()) == generatedPem}`);

console.log(`sync refusals sha1 ${!signSync(key, "abc", "sha1").ok} bits ${!RsaPrivateKey.generateSync(1024).ok} weak key ${!RsaPrivateKey.importPemSync("-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----\n").ok}`);
