import {
	EcCurve, EcPrivateKey, EcPublicKey, ecdsaSignSync, ecdsaVerifySync, ecdhSync,
} from "./ecNative";
import {
	EcPrivateKey as VendorPrivateKey, EcPublicKey as VendorPublicKey,
	ecdsaSignSync as vendorSign, ecdsaVerifySync as vendorVerify, ecdhSync as vendorEcdh,
} from "../ec";

let sink: number = 0;

function opsPerSecond(op: () => void): number {
	let calls = 1;
	while (true) {
		const start = performance.now();
		for (let i = 0; i < calls; i++) op();
		const elapsed = performance.now() - start;
		if (elapsed >= 100.0) return calls * 1000.0 / elapsed;
		calls = calls * 2;
	}
}

function median(values: number[]): number {
	const sorted = values.slice(0).sort((a, b) => a - b);
	return sorted[sorted.length >> 1];
}

function must<T, E>(result: Result<T, E>): T {
	if (!result.ok) throw new Error("bench setup failed");
	return result.value;
}

function report(name: string, pure: number[], vendor: number[]): void {
	const p = median(pure);
	const v = median(vendor);
	console.log(`${name}: pure ${p.toFixed(0)} ops/s, vendor ${v.toFixed(0)} ops/s, pure/vendor ${(p / v).toFixed(2)}`);
}

const curves: EcCurve[] = ["p256", "p384"];
for (const curve of curves) {
	const hash = curve == "p256" ? "sha256" : "sha384";
	const key = must(EcPrivateKey.generateSync(curve));
	const peer = must(EcPrivateKey.generateSync(curve));
	const keyPem = must(key.exportPemSync());
	const peerPublicPem = must(peer.publicKey().exportPemSync());
	const vendorKey = must(VendorPrivateKey.importPemSync(keyPem));
	const vendorPeer = must(VendorPublicKey.importPemSync(peerPublicPem));
	const pureSig = must(ecdsaSignSync(key, "bench message", hash));
	const vendorSig = must(vendorSign(vendorKey, "bench message", hash));
	const pureSign: number[] = [];
	const vendorSignRate: number[] = [];
	const pureVerify: number[] = [];
	const vendorVerifyRate: number[] = [];
	const pureEcdh: number[] = [];
	const vendorEcdhRate: number[] = [];
	for (let round = 0; round < 5; round++) {
		pureSign.push(opsPerSecond(() => { sink += must(ecdsaSignSync(key, "bench message", hash)).length; }));
		vendorSignRate.push(opsPerSecond(() => { sink += must(vendorSign(vendorKey, "bench message", hash)).length; }));
		pureVerify.push(opsPerSecond(() => { if (ecdsaVerifySync(key.publicKey(), "bench message", vendorSig, hash)) sink += 1; }));
		vendorVerifyRate.push(opsPerSecond(() => { if (vendorVerify(vendorKey.publicKey(), "bench message", pureSig, hash)) sink += 1; }));
		pureEcdh.push(opsPerSecond(() => { sink += must(ecdhSync(key, peer.publicKey())).length; }));
		vendorEcdhRate.push(opsPerSecond(() => { sink += must(vendorEcdh(vendorKey, vendorPeer)).length; }));
	}
	report(`${curve} sign`, pureSign, vendorSignRate);
	report(`${curve} verify`, pureVerify, vendorVerifyRate);
	report(`${curve} ecdh`, pureEcdh, vendorEcdhRate);
}
console.log(`sink ${sink}`);
