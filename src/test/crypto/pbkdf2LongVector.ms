import { pbkdf2Sync } from "std/crypto/pure/kdfNative";
import { encodeHex } from "std/core/encoding";

test "PBKDF2 SHA1 matches Wycheproof tcId 4 at 16777216 iterations" {
	const result = pbkdf2Sync("password", "salt", 16777216, 20, "sha1");
	assert result.ok;
	assert result.value.encodeHex() ==
		"eefe3d61cd4da4e4e9945b3d6ba2158c2634e984";
}
