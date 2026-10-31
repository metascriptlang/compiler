// ECDH over P-256 and P-384: both parties derive the same secret, and a third key derives another.
//
// @stdout: p256 agree true other false|p384 agree true other false
// @exit: 0
// @skip-js: std/crypto/rsa has only a C backend (index.cms over mbedTLS); there is no rsa.jms
// @skip-raiser: std/crypto/rsa has only a C backend (index.cms over mbedTLS); there is no rsa.rms

import { Buffer } from "std/core/buffer";
import { ecGenerate, ecdhDerive, ecFree } from "std/crypto/rsa";

function same(a: Buffer, b: Buffer): boolean {
	if (a.length != b.length) return false;
	for (let i = 0; i < a.length; i++) {
		if (a[i] != b[i]) return false;
	}
	return true;
}

function row(curve: string): string {
	const a = ecGenerate(curve);
	const b = ecGenerate(curve);
	const c = ecGenerate(curve);
	if (!a.ok || !b.ok || !c.ok) throw new Error("ecGenerate failed");
	const ab = ecdhDerive(a.value, b.value);
	const ba = ecdhDerive(b.value, a.value);
	const ac = ecdhDerive(a.value, c.value);
	if (!ab.ok || !ba.ok || !ac.ok) throw new Error("ecdhDerive failed");
	const agree = same(ab.value, ba.value) && ab.value.length > 0;
	const other = same(ab.value, ac.value);
	ecFree(a.value);
	ecFree(b.value);
	ecFree(c.value);
	return `${curve} agree ${agree} other ${other}`;
}

console.log([row("p256"), row("p384")].join("|"));
