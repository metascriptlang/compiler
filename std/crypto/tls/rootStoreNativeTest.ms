import {
	join,
	mkdir,
	readFileBytes,
	removeAll,
	writeFile,
	writeFileBytes,
} from "std/fs";
import { tmpDir } from "std/os";
import { env } from "std/process";
import { CryptoError } from "../errors";
import {
	EnvLookup,
	RootStore,
	certificatesInFile,
	loadCaSource,
	loadRootStore,
	defaultRootStore,
	pemCertificates,
	resolveRootStore,
	systemCaCandidates,
	windowsCaCandidates,
} from "./rootStore";
import { MACOS_KEYCHAIN_PATHS, keychainCertificates } from "./rootStoreKeychain";

const CERT_A: uint8[] = [0x30, 0x03, 0x02, 0x01, 0x05];
const CERT_B: uint8[] = [0x30, 0x04, 0x04, 0x02, 0xab, 0xcd];

function pemBlock(label: string, der: uint8[], eol: string): string {
	return `-----BEGIN ${label}-----${eol}${der.encodeBase64()}${eol}` +
		`-----END ${label}-----${eol}`;
}

function sameBytes(a: Readonly<uint8[]>, b: Readonly<uint8[]>): boolean {
	if (a.length != b.length) return false;
	for (let i = 0; i < a.length; i++) {
		if (a[i] != b[i]) return false;
	}
	return true;
}

function scratchDir(name: string): string {
	const dir = join(tmpDir(), `msRootStore-${name}-${Date.now()}`);
	removeAll(dir);
	if (!mkdir(dir).ok) throw new Error(`cannot create ${dir}`);
	return dir;
}

function loadedStore(
	result: Result<RootStore, CryptoError>,
): RootStore {
	if (!result.ok) throw new Error(result.error.message);
	return result.value;
}

function noEnv(name: string): string {
	return "";
}

test "pem bundle skips junk and other block types" {
	const text = "subject=junk line\n" +
		pemBlock("PRIVATE KEY", CERT_B, "\n") +
		pemBlock("CERTIFICATE", CERT_A, "\n") +
		"# comment between blocks\n" +
		"-----BEGIN CERTIFICATE-----\n!!!not base64!!!\n" +
		"-----END CERTIFICATE-----\n" +
		pemBlock("CERTIFICATE", CERT_B, "\n");
	const certs = pemCertificates(text);
	assert certs.length == 2;
	assert sameBytes(certs[0], CERT_A);
	assert sameBytes(certs[1], CERT_B);
}

test "pem bundle with CRLF line endings" {
	const text = pemBlock("CERTIFICATE", CERT_A, "\r\n") +
		pemBlock("CERTIFICATE", CERT_B, "\r\n");
	const certs = pemCertificates(text);
	assert certs.length == 2;
	assert sameBytes(certs[1], CERT_B);
}

test "a begin marker without its end stops the scan" {
	const text = pemBlock("CERTIFICATE", CERT_A, "\n") +
		"-----BEGIN CERTIFICATE-----\nMAMCAQU=\n";
	assert pemCertificates(text).length == 1;
}

test "explicit file loads every certificate it holds" {
	const dir = scratchDir("file");
	const path = join(dir, "bundle.pem");
	assert writeFile(path, pemBlock("CERTIFICATE", CERT_A, "\n") +
		pemBlock("CERTIFICATE", CERT_B, "\n")).ok;
	const store = resolveRootStore(path, noEnv, []);
	assert store.ok;
	assert store.value.anchors.length == 2;
	assert store.value.source == path;
	assert store.value.anchors[0].source == path;
	removeAll(dir);
}

test "a DER file is one certificate" {
	const dir = scratchDir("der");
	const path = join(dir, "one.der");
	assert writeFileBytes(path, CERT_B).ok;
	const certs = certificatesInFile(path);
	assert certs.length == 1;
	assert sameBytes(certs[0], CERT_B);
	removeAll(dir);
}

test "explicit directory loads each regular file" {
	const dir = scratchDir("dir");
	assert writeFile(join(dir, "a.pem"), pemBlock("CERTIFICATE", CERT_A, "\n")).ok;
	assert writeFile(join(dir, "b.crt"), pemBlock("CERTIFICATE", CERT_B, "\n")).ok;
	assert writeFile(join(dir, "README"), "not a certificate\n").ok;
	assert mkdir(join(dir, "nested")).ok;
	const anchors = loadCaSource(dir);
	assert anchors.length == 2;
	const store = resolveRootStore(dir, noEnv, []);
	assert store.ok;
	assert store.value.anchors.length == 2;
	removeAll(dir);
}

test "a named source that loads nothing is an error" {
	const missing = join(tmpDir(), "msRootStore-missing-none.pem");
	const explicit = resolveRootStore(missing, noEnv, []);
	assert !explicit.ok;
	assert explicit.error.message ==
		`failed to load CA certificates from ${missing}`;
	const fromEnv: EnvLookup = (name: string): string =>
		name == "SSL_CERT_FILE" ? missing : "";
	const envResult = resolveRootStore(null, fromEnv, []);
	assert !envResult.ok;
	assert envResult.error.message ==
		`no CA certificates found: SSL_CERT_FILE=${missing} did not load`;
	const none = resolveRootStore(null, noEnv, [missing]);
	assert !none.ok;
	assert none.error.message ==
		"no CA certificates found; set SSL_CERT_FILE or SSL_CERT_DIR";
}

test "environment order: SSL_CERT_FILE, SSL_CERT_DIR, then candidates" {
	const dir = scratchDir("env");
	const fileA = join(dir, "a.pem");
	const fileB = join(dir, "b.pem");
	assert writeFile(fileA, pemBlock("CERTIFICATE", CERT_A, "\n")).ok;
	assert writeFile(fileB, pemBlock("CERTIFICATE", CERT_B, "\n")).ok;
	const both: EnvLookup = (name: string): string =>
		name == "SSL_CERT_FILE" ? fileA : (name == "SSL_CERT_DIR" ? dir : "");
	assert loadedStore(resolveRootStore(null, both, [fileB])).source == fileA;
	const dirOnly: EnvLookup = (name: string): string =>
		name == "SSL_CERT_DIR" ? dir : "";
	const fromDir = loadedStore(resolveRootStore(null, dirOnly, [fileB]));
	assert fromDir.source == dir;
	assert fromDir.anchors.length == 2;
	const skipMissing = loadedStore(
		resolveRootStore(null, noEnv, [join(dir, "x"), fileB]),
	);
	assert skipMissing.source == fileB;
	removeAll(dir);
}

test "SSL_CERT_FILE in the process environment overrides the OS list" {
	const dir = scratchDir("procenv");
	const path = join(dir, "only.pem");
	assert writeFile(path, pemBlock("CERTIFICATE", CERT_A, "\n")).ok;
	const saved = env.get("SSL_CERT_FILE");
	assert env.set("SSL_CERT_FILE", path);
	const store = loadRootStore(null);
	if (saved == "") env.delete("SSL_CERT_FILE");
	else env.set("SSL_CERT_FILE", saved);
	assert store.ok;
	assert store.value.source == path;
	assert store.value.anchors.length == 1;
	removeAll(dir);
}

test "windows candidates: beside the executable, then PATH" {
	const list = windowsCaCandidates(
		"C:\\app\\bin\\tool.exe",
		"C:\\a;\"C:\\b c\";;D:\\d",
	);
	assert list.length == 4;
	assert list[0] == "C:\\app\\bin\\cacert.pem";
	assert list[1] == "C:\\a\\cacert.pem";
	assert list[2] == "C:\\b c\\cacert.pem";
	assert list[3] == "D:\\d\\cacert.pem";
}

test "host default root store loads anchors" {
	assert systemCaCandidates(noEnv).length > 0;
	const store = defaultRootStore();
	assert store.ok;
	assert store.value.anchors.length > 0;
	console.log(
		`default root store: ${store.value.anchors.length} anchors from ` +
		store.value.source,
	);
	assert loadedStore(defaultRootStore()).anchors.length ==
		store.value.anchors.length;
}

function pushWord(out: uint8[], value: int64): void {
	out.push(((value >> 24) & 255) as uint8);
	out.push(((value >> 16) & 255) as uint8);
	out.push(((value >> 8) & 255) as uint8);
	out.push((value & 255) as uint8);
}

function pushWords(out: uint8[], values: int64[]): void {
	for (const value of values) pushWord(out, value);
}

function syntheticKeychain(): uint8[] {
	const bytes: uint8[] = [];
	for (const c of "kych".asBytes()) bytes.push(c);
	pushWords(bytes, [0x10000, 0x10, 20, 0]);
	pushWords(bytes, [0, 2, 16, 64]);
	pushWords(bytes, [0, 0x0f, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
	pushWords(bytes, [0, 0x80001000, 3, 0, 0, 0, 0, 0, 40, 0]);
	pushWords(bytes, [0, 0, 0, 0, CERT_A.length as int64]);
	pushWords(bytes, [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
	for (const b of CERT_A) bytes.push(b);
	return bytes;
}

test "keychain reader takes the X.509 table records only" {
	const certs = keychainCertificates(syntheticKeychain());
	assert certs.length == 1;
	assert sameBytes(certs[0], CERT_A);
	assert keychainCertificates(CERT_B).length == 0;
}

test "host system root keychain holds certificates" {
	when (macos) {
		const bytes = readFileBytes(MACOS_KEYCHAIN_PATHS[0]);
		assert bytes.ok;
		const certs = keychainCertificates(bytes.value);
		console.log(`system root keychain: ${certs.length} certificates`);
		assert certs.length > 0;
		assert certs[0][0] == 0x30;
	}
}
