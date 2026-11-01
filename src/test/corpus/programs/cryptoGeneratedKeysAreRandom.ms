// @stdout: ed25519 32 distinct true x25519 32 distinct true
// @exit: 0
// @skip-js: std/crypto has only a C backend; there is no .jms
// @skip-raiser: the raiser std/crypto carries only the string-encoded hash family
import { Buffer } from "std/core/buffer";
import { Ed25519PrivateKey } from "std/crypto/ed25519";
import { X25519PrivateKey } from "std/crypto/x25519";

function signSeed(): Buffer | null {
	const key = Ed25519PrivateKey.generateSync();
	if (!key.ok) return null;
	const seed = key.value.exportSeedSync();
	return seed.ok ? seed.value : null;
}

function dhPublic(): Buffer | null {
	const key = X25519PrivateKey.generateSync();
	if (!key.ok) return null;
	const raw = key.value.publicKey().exportSync();
	return raw.ok ? raw.value : null;
}

const signA = signSeed();
const signB = signSeed();
const dhA = dhPublic();
const dhB = dhPublic();
const signLength = signA != null ? signA.length : -1;
const dhLength = dhA != null ? dhA.length : -1;
const signDistinct = signA != null && signB != null && Buffer.compare(signA, signB) != 0;
const dhDistinct = dhA != null && dhB != null && Buffer.compare(dhA, dhB) != 0;
console.log(`ed25519 ${signLength} distinct ${signDistinct} x25519 ${dhLength} distinct ${dhDistinct}`);
