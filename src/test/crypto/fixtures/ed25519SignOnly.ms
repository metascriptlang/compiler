import {
	ed25519PublicFromSeed,
	ed25519Sign,
} from "std/crypto/pure/ed25519";
import { encodeHex } from "std/core/encoding";

const seed = new Array<uint8>(32);
const publicKey = ed25519PublicFromSeed(seed);
const signature = ed25519Sign(seed, publicKey, []);
console.log(signature.encodeHex());
