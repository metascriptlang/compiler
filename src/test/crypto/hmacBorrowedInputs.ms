import { Buffer } from "std/core/buffer";
import { HashAlgorithm, hmacSync } from "std/crypto";
import { hmacOf } from "../../../std/crypto/pure/hmac";
import {
	kindSha256, kindSha512, kindMd5,
} from "../../../std/crypto/pure/state";

const kinds: int32[] = [kindSha256, kindSha512, kindMd5];
const names: HashAlgorithm[] = ["sha256", "sha512", "md5"];

test "HMAC borrowed inputs match native bytes without changing owners" {
	for (const keyText of ["key", "k".repeat(200)]) {
		for (const dataText of ["", "hé\0😀", "m".repeat(64)]) {
			const key = Buffer.fromString(keyText, "utf8");
			const data = Buffer.fromString(dataText, "utf8");
			const keyBefore = key.encodeHex();
			const dataBefore = data.encodeHex();
			for (let index = 0; index < kinds.length; index++) {
				const expected = hmacSync(names[index], key, data);
				assert expected.ok;
				let digest: uint8[];
				when (c) {
					digest = hmacOf(
						kinds[index], keyText.asBytes(), dataText.asBytes(),
					);
				} else {
					digest = hmacOf(kinds[index], key, data);
				}
				assert digest.encodeHex() == expected.value.encodeHex();
				assert key.encodeHex() == keyBefore;
				assert data.encodeHex() == dataBefore;
			}
		}
	}
}
