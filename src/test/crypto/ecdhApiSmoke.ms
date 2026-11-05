import { EcPrivateKey, EcPublicKey, ecdhSync } from "std/crypto/pure/ecNative";
import { ownCurve, ecPrivateToSec1 } from "std/crypto/pure/weierstrass";
import { pemEncode } from "std/crypto/pure/pem";
import { p256 } from "std/crypto/pure/p256";
import { p384 } from "std/crypto/pure/p384";
import { readFile } from "std/fs";

const vectorDir = "std/crypto/test/vectors/";

interface EcdhCase {
	tcId: int32;
	public: string;
	private: string;
	shared: string;
	result: string;
}

interface EcdhGroup {
	tests: EcdhCase[];
}

interface EcdhFile {
	testGroups: EcdhGroup[];
}

function padScalar(hex: string, size: int32): uint8[] {
	const raw = hex.decodeHex();
	let start = 0;
	while (start < raw.length && raw[start] == 0) start++;
	const len = raw.length - start;
	if (len > size) throw new Error(`ECDH smoke: scalar too long: ${len} > ${size}`);
	const out = new Array<uint8>(size);
	for (let i = 0; i < len; i++) out[size - len + i] = raw[start + i];
	return out;
}

test "ECDH smoke P-256: first 32 valid Wycheproof cases agree with vector shared secret" {
	const name = "ecdh_secp256r1_test.json";
	const curve = ownCurve(p256);
	const text = readFile(vectorDir + name);
	assert text.ok, `${name}: cannot read`;
	const parsed = JSON.parse<EcdhFile>(text.value);
	assert parsed.ok, `${name}: parse error`;
	const groups = parsed.value.testGroups;
	assert groups.length == 1, `${name}: expected 1 group, got ${groups.length}`;
	let validTotal = 0;
	let selected = 0;
	for (const tc of groups[0].tests) {
		if (tc.result != "valid" && tc.result != "invalid" && tc.result != "acceptable")
			throw new Error(`${name} #${tc.tcId}: unexpected result label '${tc.result}'`);
		if (tc.result == "valid") validTotal++;
		if (tc.result == "valid" && selected < 32) {
			selected++;
			const publicKey = EcPublicKey.importPemSync(pemEncode("PUBLIC KEY", tc.public.decodeHex()));
			if (!publicKey.ok) throw new Error(`${name} #${tc.tcId}: public key import failed: ${publicKey.error.message}`);
			assert publicKey.value.curve == "p256", `${name} #${tc.tcId}: public key curve ${publicKey.value.curve}`;
			const d = padScalar(tc.private, curve.size);
			const privateKey = EcPrivateKey.importPemSync(pemEncode("EC PRIVATE KEY", ecPrivateToSec1({ curve, d, point: [] })));
			if (!privateKey.ok) throw new Error(`${name} #${tc.tcId}: private key import failed: ${privateKey.error.message}`);
			assert privateKey.value.curve == "p256", `${name} #${tc.tcId}: private key curve ${privateKey.value.curve}`;
			const shared = ecdhSync(privateKey.value, publicKey.value);
			if (!shared.ok) throw new Error(`${name} #${tc.tcId}: ecdhSync failed: ${shared.error.message}`);
			assert shared.value.length == 32, `${name} #${tc.tcId}: output width ${shared.value.length}`;
			const actual = shared.value.encodeHex();
			assert actual == tc.shared, `${name} #${tc.tcId}: shared mismatch: got ${actual}`;
		}
	}
	assert selected == 32, `${name}: selected ${selected}/32 valid cases`;
	assert validTotal == 330, `${name}: total valid ${validTotal}`;
}

test "ECDH smoke P-384: first 32 valid Wycheproof cases agree with vector shared secret" {
	const name = "ecdh_secp384r1_test.json";
	const curve = ownCurve(p384);
	const text = readFile(vectorDir + name);
	assert text.ok, `${name}: cannot read`;
	const parsed = JSON.parse<EcdhFile>(text.value);
	assert parsed.ok, `${name}: parse error`;
	const groups = parsed.value.testGroups;
	assert groups.length == 1, `${name}: expected 1 group, got ${groups.length}`;
	let validTotal = 0;
	let selected = 0;
	for (const tc of groups[0].tests) {
		if (tc.result != "valid" && tc.result != "invalid" && tc.result != "acceptable")
			throw new Error(`${name} #${tc.tcId}: unexpected result label '${tc.result}'`);
		if (tc.result == "valid") validTotal++;
		if (tc.result == "valid" && selected < 32) {
			selected++;
			const publicKey = EcPublicKey.importPemSync(pemEncode("PUBLIC KEY", tc.public.decodeHex()));
			if (!publicKey.ok) throw new Error(`${name} #${tc.tcId}: public key import failed: ${publicKey.error.message}`);
			assert publicKey.value.curve == "p384", `${name} #${tc.tcId}: public key curve ${publicKey.value.curve}`;
			const d = padScalar(tc.private, curve.size);
			const privateKey = EcPrivateKey.importPemSync(pemEncode("EC PRIVATE KEY", ecPrivateToSec1({ curve, d, point: [] })));
			if (!privateKey.ok) throw new Error(`${name} #${tc.tcId}: private key import failed: ${privateKey.error.message}`);
			assert privateKey.value.curve == "p384", `${name} #${tc.tcId}: private key curve ${privateKey.value.curve}`;
			const shared = ecdhSync(privateKey.value, publicKey.value);
			if (!shared.ok) throw new Error(`${name} #${tc.tcId}: ecdhSync failed: ${shared.error.message}`);
			assert shared.value.length == 48, `${name} #${tc.tcId}: output width ${shared.value.length}`;
			const actual = shared.value.encodeHex();
			assert actual == tc.shared, `${name} #${tc.tcId}: shared mismatch: got ${actual}`;
		}
	}
	assert selected == 32, `${name}: selected ${selected}/32 valid cases`;
	assert validTotal == 771, `${name}: total valid ${validTotal}`;
}
