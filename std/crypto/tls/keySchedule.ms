/**
 * The TLS 1.3 key schedule (RFC 8446 7.1): HKDF-Extract, HKDF-Expand-Label,
 * Derive-Secret and the traffic key and IV of a secret.
 */

import { newHmac, updateHmac, finishHmacInto, hmacOf } from "../pure/hmac";
import { hashOf } from "../pure/hash";
import { newHashState } from "../pure/state";

export function hashLength(kind: int32): int32 {
	return newHashState(kind).outputSize;
}

/** HKDF-Extract (RFC 5869 2.2); an empty salt is the hash length of zeros. */
export function hkdfExtract(
	kind: int32,
	salt: Readonly<uint8[]>,
	ikm: Readonly<uint8[]>,
): uint8[] {
	if (salt.length == 0) return hmacOf(kind, new Array<uint8>(hashLength(kind)), ikm);
	return hmacOf(kind, salt, ikm);
}

/** HKDF-Expand (RFC 5869 2.3). */
export function hkdfExpand(
	kind: int32,
	prk: Readonly<uint8[]>,
	info: Readonly<uint8[]>,
	length: int32,
): uint8[] {
	const size = hashLength(kind);
	const hmac = newHmac(kind, prk);
	const out = new Array<uint8>(length);
	const block = new Array<uint8>(size);
	const counter = new Array<uint8>(1);
	let written = 0;
	let index = 1;
	while (written < length) {
		if (index > 1) updateHmac(hmac, block);
		updateHmac(hmac, info);
		counter[0] = index as uint8;
		updateHmac(hmac, counter);
		finishHmacInto(hmac, block);
		for (let i = 0; i < size && written < length; i++) {
			out[written] = block[i];
			written += 1;
		}
		index += 1;
	}
	return out;
}

/** The HkdfLabel structure: uint16 length, "tls13 " + label, context. */
export function hkdfLabel(
	label: string,
	context: Readonly<uint8[]>,
	length: int32,
): uint8[] {
	const name = ("tls13 " + label).asBytes();
	const out: uint8[] = [((length >> 8) & 255) as uint8, (length & 255) as uint8];
	out.push(name.length as uint8);
	for (let i = 0; i < name.length; i++) out.push(name[i]);
	out.push(context.length as uint8);
	for (let i = 0; i < context.length; i++) out.push(context[i]);
	return out;
}

export function hkdfExpandLabel(
	kind: int32,
	secret: Readonly<uint8[]>,
	label: string,
	context: Readonly<uint8[]>,
	length: int32,
): uint8[] {
	return hkdfExpand(kind, secret, hkdfLabel(label, context, length), length);
}

/** Derive-Secret over an already computed transcript hash. */
export function deriveSecret(
	kind: int32,
	secret: Readonly<uint8[]>,
	label: string,
	transcriptHash: Readonly<uint8[]>,
): uint8[] {
	return hkdfExpandLabel(kind, secret, label, transcriptHash, hashLength(kind));
}

export function emptyHash(kind: int32): uint8[] {
	return hashOf(kind, []);
}

/** The secrets one handshake derives, in the order RFC 8446 7.1 derives them. */
export class KeySchedule {
	kind: int32;
	earlySecret: uint8[];
	handshakeSecret: uint8[];
	masterSecret: uint8[];
	clientHandshakeSecret: uint8[];
	serverHandshakeSecret: uint8[];
	clientApplicationSecret: uint8[];
	serverApplicationSecret: uint8[];
}

/** Early, handshake and master secrets plus both handshake traffic secrets, from the (EC)DHE secret and Hash(ClientHello..ServerHello). */
export function handshakeSchedule(
	kind: int32,
	sharedSecret: Readonly<uint8[]>,
	helloHash: Readonly<uint8[]>,
): KeySchedule {
	const zeroes = new Array<uint8>(hashLength(kind));
	const empty = emptyHash(kind);
	const earlySecret = hkdfExtract(kind, [0], zeroes);
	const handshakeSalt = deriveSecret(kind, earlySecret, "derived", empty);
	const handshakeSecret = hkdfExtract(kind, handshakeSalt, sharedSecret);
	const masterSalt = deriveSecret(kind, handshakeSecret, "derived", empty);
	return {
		kind,
		earlySecret,
		handshakeSecret,
		masterSecret: hkdfExtract(kind, masterSalt, zeroes),
		clientHandshakeSecret: deriveSecret(kind, handshakeSecret, "c hs traffic", helloHash),
		serverHandshakeSecret: deriveSecret(kind, handshakeSecret, "s hs traffic", helloHash),
		clientApplicationSecret: [],
		serverApplicationSecret: [],
	};
}

/** Both application traffic secrets from Hash(ClientHello..server Finished). */
export function applicationSchedule(
	schedule: KeySchedule,
	handshakeHash: Readonly<uint8[]>,
): void {
	const kind = schedule.kind;
	schedule.clientApplicationSecret = deriveSecret(kind, schedule.masterSecret, "c ap traffic", handshakeHash);
	schedule.serverApplicationSecret = deriveSecret(kind, schedule.masterSecret, "s ap traffic", handshakeHash);
}

/** verify_data of a Finished message (RFC 8446 4.4.4). */
export function finishedVerifyData(
	kind: int32,
	trafficSecret: Readonly<uint8[]>,
	transcriptHash: Readonly<uint8[]>,
): uint8[] {
	const finishedKey = hkdfExpandLabel(kind, trafficSecret, "finished", [], hashLength(kind));
	return hmacOf(kind, finishedKey, transcriptHash);
}
