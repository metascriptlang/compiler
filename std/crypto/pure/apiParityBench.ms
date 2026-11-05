import { Buffer } from "std/core/buffer";
import { argv } from "std/process";
import { CryptoError } from "../errors";
import {
	AesKey as NAesKey, sealSync as nAesSeal, openSync as nAesOpen,
} from "../aes";
import {
	AesKey as PAesKey, sealSync as pAesSeal,
} from "./aesNative";
import {
	ChaChaKey as NChaChaKey, sealSync as nChachaSeal, openSync as nChachaOpen,
} from "../chacha20";
import {
	ChaChaKey as PChaChaKey, sealSync as pChachaSeal,
} from "./chachaNative";
import {
	Ed25519PrivateKey as NEdKey, signSync as nEdSign, verifySync as nEdVerify,
} from "../ed25519";
import {
	Ed25519PrivateKey as PEdKey, signSync as pEdSign, verifySync as pEdVerify,
} from "./ed25519Native";
import {
	X25519PrivateKey as NXKey, X25519PublicKey as NXPub,
	sharedSecretSync as nXShared,
} from "../x25519";
import {
	X25519PrivateKey as PXKey, X25519PublicKey as PXPub,
	sharedSecretSync as pXShared,
} from "./x25519Native";
import { blake2bSync as nBlake } from "../blake2b";
import { blake2bSync as pBlake } from "./blake2bNative";

let sink: number = 0;

function must<T>(sink result: Result<T, CryptoError>): T {
	if (!result.ok) throw new Error(result.error.message);
	return result.value;
}

function pattern(length: int32, salt: int32): Buffer {
	const bytes = new Array<uint8>(length);
	for (let i: int32 = 0; i < length; i++) {
		bytes[i] = ((i * 31 + salt) & 255) as uint8;
	}
	return bytes as Buffer;
}

function nsPerCall(operation: () => number): number {
	let calls: int32 = 16;
	while (true) {
		const start = performance.now();
		for (let call = 0; call < calls; call++) sink += operation();
		const elapsed = performance.now() - start;
		if (elapsed >= 20) return elapsed * 1000000 / calls;
		if (calls >= 16777216) throw new Error("timer did not reach 20 ms");
		calls *= 4;
	}
}

function median(values: number[]): number {
	const sorted = values.slice(0).sort((a, b) => a - b);
	return sorted[sorted.length >> 1];
}

const message = pattern(64, 7);
const bulk = pattern(16384, 9);
const aesRaw = pattern(32, 1);
const chachaRaw = pattern(32, 2);
const seed = pattern(32, 3);
const xSecret = pattern(32, 4);
const xPeerSecret = pattern(32, 5);

const nAes = must(NAesKey.import(aesRaw));
const pAes = must(PAesKey.import(aesRaw));
const nChacha = must(NChaChaKey.import(chachaRaw));
const pChacha = must(PChaChaKey.import(chachaRaw));
const nEd = must(NEdKey.fromSeedSync(seed));
const pEd = must(PEdKey.fromSeedSync(seed));
const nEdPub = nEd.publicKey();
const pEdPub = pEd.publicKey();
const edSig = must(nEdSign(nEd, message));
const nX = must(NXKey.fromRawSync(xSecret));
const pX = must(PXKey.fromRawSync(xSecret));
const peerRaw = must(must(NXKey.fromRawSync(xPeerSecret))
	.publicKey().exportSync());
const nPeer = must(NXPub.importSync(peerRaw));
const pPeer = must(PXPub.importSync(peerRaw));

if (must(pEdSign(pEd, message)).encodeHex() != edSig.encodeHex()) {
	throw new Error("ed25519 signature mismatch");
}
if (!pEdVerify(pEdPub, edSig, message)) throw new Error("ed25519 verify");
if (must(pXShared(pX, pPeer)).encodeHex() !=
	must(nXShared(nX, nPeer)).encodeHex()) {
	throw new Error("x25519 shared mismatch");
}
for (const data of [message, bulk]) {
	if (must(pBlake(data)).encodeHex() !=
		must(nBlake(data)).encodeHex()) {
		throw new Error("blake2b mismatch");
	}
	const aesSealed = must(pAesSeal(pAes, data));
	if (must(nAesOpen(nAes, aesSealed)).encodeHex() != data.encodeHex()) {
		throw new Error("aes cross-open mismatch");
	}
	const chachaSealed = must(pChachaSeal(pChacha, data));
	if (must(nChachaOpen(nChacha, chachaSealed)).encodeHex() !=
		data.encodeHex()) {
		throw new Error("chacha cross-open mismatch");
	}
}

const names = [
	"aes-gcm-seal-64", "aes-gcm-seal-16k", "chacha-seal-64", "chacha-seal-16k",
	"ed25519-sign-64", "ed25519-verify-64", "x25519-shared",
	"blake2b-64", "blake2b-16k",
];
const native: (() => number)[] = [
	() => must(nAesSeal(nAes, message))[0],
	() => must(nAesSeal(nAes, bulk))[0],
	() => must(nChachaSeal(nChacha, message))[0],
	() => must(nChachaSeal(nChacha, bulk))[0],
	() => must(nEdSign(nEd, message))[0],
	() => nEdVerify(nEdPub, edSig, message) ? 1 : 0,
	() => must(nXShared(nX, nPeer))[0],
	() => must(nBlake(message))[0],
	() => must(nBlake(bulk))[0],
];
const pure: (() => number)[] = [
	() => must(pAesSeal(pAes, message))[0],
	() => must(pAesSeal(pAes, bulk))[0],
	() => must(pChachaSeal(pChacha, message))[0],
	() => must(pChachaSeal(pChacha, bulk))[0],
	() => must(pEdSign(pEd, message))[0],
	() => pEdVerify(pEdPub, edSig, message) ? 1 : 0,
	() => must(pXShared(pX, pPeer))[0],
	() => must(pBlake(message))[0],
	() => must(pBlake(bulk))[0],
];
console.log(`api parity checks passed for ${names.length} operations`);

if (argv.includes("--measure")) {
	for (let op = 0; op < names.length; op++) {
		const ns: number[] = [];
		const ps: number[] = [];
		for (let round = 0; round < 5; round++) {
			if (round % 2 == 0) {
				ns.push(nsPerCall(native[op]));
				ps.push(nsPerCall(pure[op]));
			} else {
				ps.push(nsPerCall(pure[op]));
				ns.push(nsPerCall(native[op]));
			}
		}
		const n = median(ns);
		const p = median(ps);
		console.log(`${names[op]} native=${n.toFixed(1)} pure=${p.toFixed(1)} ns pure/native=${(p / n).toFixed(3)}`);
	}
	console.log(`sink=${sink}`);
}
