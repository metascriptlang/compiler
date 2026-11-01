// A key that goes out of scope is destroyed once: RSA and EC private keys, the public keys taken from
// them and keys imported from PEM are made, used and dropped by scope exit, repeatedly. More scopes
// than the 32 PSA key slots of the process would hold if a key kept one; under SAN a missing destroy
// is a leak and a second one is a double free, and the DRC ledger must balance.
//
// @stdout: scopes 60 signed 60 derived 60 oaep 60
// @exit: 0
// @skip-raiser: std/crypto/rsa has a C and a JS backend and no rsa.rms

import { Buffer } from "std/core/buffer";
import { RsaPrivateKey, sign, verify, encrypt, decrypt } from "std/crypto/rsa";
import { EcCurve, EcPrivateKey, ecdh } from "std/crypto/ec";

const rsaPem = [
	"-----BEGIN RSA PRIVATE KEY-----",
	"MIIEowIBAAKCAQEAwLGB/nbgGfFlcx/p6TTiITyMAqRja0KB1kkXYSA4DnuxqwyL",
	"MthtmNEXBXlCMYneRcH2kul0uQqhetY1PcdQf4BJx9IHzH9ZymE7m1BDHHdAgbxv",
	"RHIdlLoFBREOuoAZZ3N4xgPPN5DbVksK7AYHN1gx0/e08OrWKvT7v8Qb1AWtXZtj",
	"/rAw27nJsWOEL2bBpMe0rU4JjOha927vzJVcYCo/8p5ieY81YLGWz0EF9ccXHCtz",
	"tOdyW5KDBlKbufT+35DylNlUm9ISjcpFeCa99oia8xSqIoJEwt/4GRv74/CM+7Gs",
	"Ch6UM9zfEzTl5fS0nWiVHAERRd0YObpQhDlg0wIDAQABAoIBAEOiSmlhmjkg5KXq",
	"7rQ/LpvR36bRwl+UgXQQRZd+so5K1kqeZYFcO+OmiDkQna47oPvFH+Hi9Wg5lgJC",
	"i396pQOLqNntG3WowYBqbnyOSHAGX2rqE/fnQgDA5iAoI45Mhh4shpiiH6p2OrZo",
	"MpYza3b+isbGrAjftHpxcKeXktjw5BuutLtZtalvlFWc9g+hVI4XBbaNG33R5uOZ",
	"hTUl+ZRNtsTdgNcPnKDLrViGi7QZt2Y4f26IGM85/6g/P0iMxvaBkViY0eClV7Wb",
	"G7GNV128kyUrtnygMRv/ezOJrYk8HzYhVeL0mX10FEFV2IUGA9LqvJ2mxv1VHEpD",
	"t8jabuECgYEA+vQJuY/5MYF0+l1fGY5H6ffLHzqCc+725rxLnkHb6OgkxSeXO+Jl",
	"e00w45KLKF+C0r3Rsgf77FRVcwFZhYeVGmi5TchFSuG+Fck25Z+xAjkL5/gM/4hc",
	"nLiSeHMnVswGnDlDmbcGGepY/yPk3Hb3xL+VfBpO5lfD1t7xfsd9b+MCgYEAxJGJ",
	"Bmmzrk9K/TBHX0KWJ3z1az2tuZNVN6wxV9sQARInkSI1mGOhemnzA/br+N441QBj",
	"xsiJSMJ2quBhyENEiBzeqBpEkl/dNOF6zFtepxsuw6HjbFIReKxViuv1UqxSl6tP",
	"GXR9ADZ3lJkeF3JGuU1GbrqWqS0QuTtbKjTQPlECgYAtIH8zMDGmdlobv3ifdtd1",
	"ukp7diEJSfp6KXgLoFo0OrKKBYGLkj2fe5UEB1Eg1HQJA3tW4Vqq98tZ3+9CNMxa",
	"MGTKGO5k9c0hy8okZqAE/08lypRDyzikMgicwlBbqlqx8xY16RSeymZwkvrPrlEF",
	"v1HZPD3d7ABafkK9ApCK8wKBgGpkm1XtQGPIZz5DM15MHBmjePJin/Uh2a4YdVyo",
	"JTFvMhtL+NZSlsQ7NF2g+HfrT7d6Tob5Y9UN7Ezwxfwu7Jj/h0RVc2gGmyRUJrMV",
	"gVXRUK5yoTWv9eTq4iIfNNlajBmrj1SnyEClOnQjrDXklIMXYFfuhj1rNvILPnzJ",
	"uS0BAoGBAO2umWPJ9FlUZBrzYvVFr0E/7nHhaG/NLT3xkVDFQeywDbNaogJ/W02I",
	"L6XuKoPakun1aQx3bjGMtFBaqyTFMWBCg4S2olCRWGp5yULklS+cKR09mN1cjfb+",
	"6Th6jv0s3yYm5Ve6Jha0zTQQRWtDKZ5w/qxR0FJ65x+fkoEQMiEO",
	"-----END RSA PRIVATE KEY-----",
].join("\n") + "\n";

let signed = 0;
let derived = 0;
let roundTrips = 0;

async function rsaScope(): Promise<void> {
	const key = await RsaPrivateKey.importPem(rsaPem);
	if (!key.ok) return;
	const pub = key.value.publicKey();
	const signature = await sign(key.value, "x");
	if (!signature.ok) return;
	const checked = await verify(pub, "x", signature.value);
	if (checked) signed += 1;
	const sealed = await encrypt(pub, "y");
	if (!sealed.ok) return;
	const opened = await decrypt(key.value, sealed.value);
	if (opened.ok && opened.value.asString() == "y") roundTrips += 1;
}

async function ecScope(curve: EcCurve): Promise<void> {
	const a = await EcPrivateKey.generate(curve);
	const b = await EcPrivateKey.generate(curve);
	if (!a.ok || !b.ok) return;
	const ab = await ecdh(a.value, b.value.publicKey());
	const ba = await ecdh(b.value, a.value.publicKey());
	if (ab.ok && ba.ok && Buffer.compare(ab.value, ba.value) == 0) derived += 1;
}

for (let i = 0; i < 60; i++) {
	await rsaScope();
	await ecScope(i % 2 == 0 ? "p256" : "p384");
}
console.log(`scopes 60 signed ${signed} derived ${derived} oaep ${roundTrips}`);
