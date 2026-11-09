import { encodeHex } from "std/core/encoding";

when (cryptoImport == "pure") {
	import { digestSync as pureDigest } from "std/crypto/pure/coreNative";
} else when (cryptoImport == "native") {
	import { digestSync as nativeDigest } from "../oracle";
}

const expected = "ba7816bf8f01cfea414140de5dae2223" +
	"b00361a396177a9cb410ff61f20015ad";

when (cryptoImport == "pure") {
	const digest = pureDigest("sha256", "abc");
	if (!digest.ok) throw new Error(digest.error.message);
	const actual = digest.value.encodeHex();
	if (actual != expected) throw new Error("pure SHA-256 size control");
	console.log(actual);
} else when (cryptoImport == "native") {
	const digest = nativeDigest("sha256", "abc");
	if (!digest.ok) throw new Error(digest.error.message);
	const actual = digest.value.encodeHex();
	if (actual != expected) throw new Error("native SHA-256 size control");
	console.log(actual);
} else {
	throw new Error("cryptoImport must be pure or native");
}
