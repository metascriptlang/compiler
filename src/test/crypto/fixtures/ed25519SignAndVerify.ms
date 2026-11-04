import {
	ed25519PublicFromSeed,
	ed25519Sign,
	ed25519Verify,
} from "std/crypto/pure/ed25519";
import { encodeHex } from "std/core/encoding";

const seed = new Array<uint8>(32);
const publicKey = ed25519PublicFromSeed(seed);
const signature = ed25519Sign(seed, publicKey, []);
if (!ed25519Verify(publicKey, signature, [])) {
	throw new Error("Ed25519 footprint control failed verification");
}
console.log(signature.encodeHex());
