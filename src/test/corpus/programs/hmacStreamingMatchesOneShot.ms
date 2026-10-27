// @stdout: sha256 0ba06f1f9a6300461e43454535dc3c4223e47b1d357073d7536eae90ec095be1 true
// @stdout: sha512 ea0625a5ff1cd1653a327f8a4ae2f478fc51405c73ddac3a8a05a7a810310a6a14d7c8b4d284013493a6016ecadc772cfd98ed6cbe745949c5e6119fafb63b54 true
// @stdout: sha1 34dd234b92683593560528f6193ea68c8005f615 true
// @stdout: md5 ae92cf51adf91130130aefc2b39a7595 true
// @stdout: long key d46761768ee3c864fc76c08b3d73c8092853ae3fefa01b990963dfa2d56e7334
// @stdout: empty key 948f7c5caa500c31d7d4a0f52f3e3da7e33c8a9fe6ef528b8a9ac3e4adc4e24d908e6f40b737510e82354759dc5e9f06
// @skip-js: std/crypto has no streaming Hmac on the JS backend
// @xfail(raiser): the raiser std/crypto has no createHmac, so the program stops at the checker
import { createHmac, hmac } from "std/crypto";

for (const algorithm of ["sha256", "sha512", "sha1", "md5"]) {
	const h = createHmac(algorithm, "key");
	h.update("hello");
	h.update("");
	h.update(" world");
	const digest = h.digest("hex");
	const oneShot = hmac(algorithm, "key", "hello world");
	console.log(algorithm, digest, oneShot.ok && digest == oneShot.value);
}

const longKey = h100();
function h100(): string {
	const parts: string[] = [];
	for (let i = 0; i < 100; i++) parts.push("k");
	return parts.join("");
}
const long = createHmac("sha256", longKey);
console.log("long key", long.digest("hex"));
const empty = createHmac("sha384", "");
empty.update("abc");
console.log("empty key", empty.digest("hex"));
