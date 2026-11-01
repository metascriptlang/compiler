// ECDH over P-256 and P-384: both parties derive the same secret, and a third key derives another.
//
// @stdout: p256 agree true other false|p384 agree true other false
// @exit: 0
// @skip-js: std/crypto/ec has only a C backend (index.cms over mbedTLS); there is no ec.jms
// @skip-raiser: std/crypto/ec has only a C backend (index.cms over mbedTLS); there is no ec.rms

import { Buffer } from "std/core/buffer";
import { EcCurve, EcPrivateKey, ecdh } from "std/crypto/ec";

function same(a: Buffer, b: Buffer): boolean {
	if (a.length != b.length) return false;
	for (let i = 0; i < a.length; i++) {
		if (a[i] != b[i]) return false;
	}
	return true;
}

async function row(curve: EcCurve): Promise<string> {
	const a = await EcPrivateKey.generate(curve);
	const b = await EcPrivateKey.generate(curve);
	const c = await EcPrivateKey.generate(curve);
	if (!a.ok || !b.ok || !c.ok) throw new Error("EcPrivateKey.generate failed");
	const ab = await ecdh(a.value, b.value.publicKey());
	const ba = await ecdh(b.value, a.value.publicKey());
	const ac = await ecdh(a.value, c.value.publicKey());
	if (!ab.ok || !ba.ok || !ac.ok) throw new Error("ecdh failed");
	const agree = same(ab.value, ba.value) && ab.value.length > 0;
	const other = same(ab.value, ac.value);
	return `${curve} agree ${agree} other ${other}`;
}

console.log([await row("p256"), await row("p384")].join("|"));
