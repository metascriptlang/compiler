// pbkdf2 and hkdf refuse a bad parameter with an error that names it, at once (iterations -1 once looped 4.29e9
// times, 0 returned the c=1 key); a keyLength over 1 MiB is refused; RFC 6070, RFC 7914 and RFC 5869 vectors still hold.
//
// @stdout: iterations 0: iterations must be at least 1
// @stdout: iterations -1: iterations must be at least 1
// @stdout: keyLength 0: keyLength must be between 1 and 1048576
// @stdout: keyLength cap+1: keyLength must be between 1 and 1048576
// @stdout: digest: unsupported digest "sha999"
// @stdout: keyLength cap ok true len 1048576
// @stdout: rfc6070 c=1 0c60c80f961f0e71f3a9b524af6012062fe037a6
// @stdout: rfc6070 c=2 ea6c014dc72d6f8ccd1ed92ace1d41f0d8de8957
// @stdout: rfc7914 55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc49ca9cccf179b645991664b39d77ef317c71b845b1e30bd509112041d3a19783
// @stdout: hkdf algorithm: unsupported algorithm "sha999"
// @stdout: hkdf length 0: length must be at least 1
// @stdout: hkdf sha256 8160: ok
// @stdout: hkdf sha256 8161: length must be at most 8160 for sha256
// @stdout: hkdf sha512 16320: ok
// @stdout: hkdf sha512 16321: length must be at most 16320 for sha512
// @stdout: hkdf rfc5869 1 3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865
// @stdout: hkdf rfc5869 3 8da4e775a563c18f715f802a063c5a31b8a11f5c5ee1879ec3454e5f3c738d2d9d201395faa4b61a96c8
// @exit: 0
// @skip-js: std/crypto has only a C backend (index.cms over runtime/crypto); there is no index.jms
// @skip-raiser: std/crypto has only a C backend (index.cms over runtime/crypto); there is no raiser random

import { Buffer } from "std/core/buffer";
import { pbkdf2, hkdf, fromHex, toHex, CryptoError } from "std/crypto";

function show(label: string, r: Result<Buffer, CryptoError>): void {
	console.log(r.ok ? `${label}: ok` : `${label}: ${r.error.message}`);
}

function hex(label: string, r: Result<Buffer, CryptoError>): void {
	console.log(r.ok ? `${label} ${toHex(r.value)}` : `${label} ${r.error.message}`);
}

show("iterations 0", pbkdf2("password", "salt", 0, 20, "sha1"));
show("iterations -1", pbkdf2("password", "salt", -1, 20, "sha1"));
show("keyLength 0", pbkdf2("password", "salt", 1, 0, "sha1"));
show("keyLength cap+1", pbkdf2("password", "salt", 1, 1048577, "sha1"));
show("digest", pbkdf2("password", "salt", 1, 20, "sha999"));

const cap = pbkdf2("password", "salt", 1, 1048576, "sha256");
console.log(`keyLength cap ok ${cap.ok} len ${cap.ok ? cap.value.length : -1}`);

hex("rfc6070 c=1", pbkdf2("password", "salt", 1, 20, "sha1"));
hex("rfc6070 c=2", pbkdf2("password", "salt", 2, 20, "sha1"));
hex("rfc7914", pbkdf2("passwd", "salt", 1, 64, "sha256"));

const ikm = fromHex("0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b");
show("hkdf algorithm", hkdf("sha999", ikm, "", "", 42));
show("hkdf length 0", hkdf("sha256", ikm, "", "", 0));
show("hkdf sha256 8160", hkdf("sha256", ikm, "", "", 8160));
show("hkdf sha256 8161", hkdf("sha256", ikm, "", "", 8161));
show("hkdf sha512 16320", hkdf("sha512", ikm, "", "", 16320));
show("hkdf sha512 16321", hkdf("sha512", ikm, "", "", 16321));
hex("hkdf rfc5869 1", hkdf("sha256", ikm, fromHex("000102030405060708090a0b0c"), fromHex("f0f1f2f3f4f5f6f7f8f9"), 42));
hex("hkdf rfc5869 3", hkdf("sha256", ikm, "", "", 42));
