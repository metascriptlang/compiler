import crypto from "node:crypto";
const P = (1n << 255n) - 19n;
const D = 37095705934669439343138083508754565189542113879843219016388785533085940283555n;
const pw = (b, e, m) => { let r = 1n; b %= m; while (e > 0n) { if (e & 1n) r = r * b % m; b = b * b % m; e >>= 1n; } return r; };
export function onCurve(bytes) {
	let y = 0n; for (let i = 31; i >= 0; i--) y = (y << 8n) | BigInt(i === 31 ? bytes[i] & 0x7f : bytes[i]);
	y %= P;
	const u = (y * y - 1n + P) % P, v = (D * y * y + 1n) % P;
	if (u === 0n) return true;
	return pw(u * pw(v, P - 2n, P) % P, (P - 1n) / 2n, P) === 1n;
}
export function hashAt(seeds, bump, programId) {
	const h = crypto.createHash("sha256");
	for (const s of seeds) h.update(s);
	h.update(Buffer.from([bump])); h.update(programId); h.update("ProgramDerivedAddress");
	return h.digest();
}
