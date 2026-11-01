// fromHex and fromBase64 return an InvalidEncoding error for input that is not well-formed (odd length, a stray
// character, missing or misplaced padding), an empty Buffer for the empty string, and the bytes otherwise.
//
// @stdout: hex ok 3 ff00fe
// @stdout: hex empty true 0
// @stdout: hex refused 8 of 8 invalid-encoding true
// @stdout: base64 ok 3 ff00fe
// @stdout: base64 empty true 0
// @stdout: base64 refused 11 of 11 invalid-encoding true
// @exit: 0
// @skip-raiser: the raiser std/crypto carries only the hash family; no fromHex or fromBase64

import { CryptoErrorKind, fromBase64, fromHex, toHex } from "std/crypto";

const okHex = fromHex("FF00fe");
console.log("hex ok", okHex.ok ? okHex.value.length : -1, okHex.ok ? toHex(okHex.value) : "");
const emptyHex = fromHex("");
console.log("hex empty", emptyHex.ok, emptyHex.ok ? emptyHex.value.length : -1);

let refused = 0;
let kindsRight = true;
const badHex = ["0", "000", "gg", "00gg", "00 0", "\0f", "é", "0x00"];
for (const text of badHex) {
	const r = fromHex(text);
	if (!r.ok) {
		refused++;
		if (r.error.kind != CryptoErrorKind.InvalidEncoding) kindsRight = false;
	}
}
console.log("hex refused", refused, "of", badHex.length, "invalid-encoding", kindsRight);

const okBase64 = fromBase64("/wD+");
console.log("base64 ok", okBase64.ok ? okBase64.value.length : -1, okBase64.ok ? toHex(okBase64.value) : "");
const emptyBase64 = fromBase64("");
console.log("base64 empty", emptyBase64.ok, emptyBase64.ok ? emptyBase64.value.length : -1);

refused = 0;
kindsRight = true;
const badBase64 = ["Zg", " Zg==", "Zg==\n", "====", "_w==", "AAA?", "AA\0A", "AA=A", "AA==AAAA", "A=AA", "AAAA=AAA"];
for (const text of badBase64) {
	const r = fromBase64(text);
	if (!r.ok) {
		refused++;
		if (r.error.kind != CryptoErrorKind.InvalidEncoding) kindsRight = false;
	}
}
console.log("base64 refused", refused, "of", badBase64.length, "invalid-encoding", kindsRight);
