/**
 * Trust anchors for certificate verification, found where the platform keeps
 * them and returned as DER certificates. Parsing them is the caller's job.
 */

import { Buffer } from "std/core/buffer";
import { exists, isDir, isFile, join, readDirNames, readFileBytes } from "std/fs";
import { env, execPath } from "std/process";
import { CryptoError, CryptoErrorKind, cryptoError } from "../errors";
import { derItem, tagSequence } from "../pure/asn1";

export interface TrustAnchor {
	der: Buffer;
	source: string;
}

export interface RootStore {
	anchors: TrustAnchor[];
	source: string;
}

export type EnvLookup = (name: string) => string;

const BEGIN_MARKER = "-----BEGIN CERTIFICATE-----";
const END_MARKER = "-----END CERTIFICATE-----";

export const MACOS_CA_PATHS: Readonly<string[]> = [
	"/etc/ssl/cert.pem",
	"/System/Library/OpenSSL/certs/cert.pem",
];

export const LINUX_CA_PATHS: Readonly<string[]> = [
	"/etc/ssl/certs/ca-certificates.crt",
	"/etc/ssl/ca-bundle.pem",
	"/etc/pki/tls/certs/ca-bundle.crt",
	"/usr/share/ssl/certs/ca-bundle.crt",
	"/etc/pki/tls/certs",
	"/data/data/com.termux/files/usr/etc/tls/cert.pem",
	"/system/etc/security/cacerts",
	"/etc/ssl/certs/ca-bundle.crt",
];

export const BSD_CA_PATHS: Readonly<string[]> = [
	"/etc/ssl/certs/ca-certificates.crt",
	"/usr/local/share/certs/ca-root-nss.crt",
	"/etc/ssl/cert.pem",
	"/usr/local/share/certs",
	"/etc/openssl/certs",
];

function rootStoreError(message: string): CryptoError {
	return cryptoError(CryptoErrorKind.CertificateError, "rootStore", message);
}

function stripWhitespace(text: string): string {
	let out = text;
	for (const space of [" ", "\t", "\r", "\n"]) out = out.split(space).join("");
	return out;
}

/**
 * Every CERTIFICATE block of a PEM text, decoded. A block whose body is not
 * base64 is skipped, and a BEGIN without its END ends the scan.
 */
export function pemCertificates(text: string): Buffer[] {
	const out: Buffer[] = [];
	let at = text.indexOf(BEGIN_MARKER);
	while (at >= 0) {
		const bodyStart = at + BEGIN_MARKER.length;
		const bodyEnd = text.indexOf(END_MARKER, bodyStart);
		if (bodyEnd < 0) break;
		const der = stripWhitespace(text.slice(bodyStart, bodyEnd))
			.decodeBase64();
		if (der.length > 0) out.push(der as Buffer);
		at = text.indexOf(BEGIN_MARKER, bodyEnd + END_MARKER.length);
	}
	return out;
}

function isWholeDerSequence(bytes: Buffer): boolean {
	const length = bytes.length as int32;
	const item = derItem(bytes, 0, length);
	return item != null && item.tag == tagSequence && item.end == length;
}

/** The certificates of one file: a PEM bundle, else one DER certificate. */
export function certificatesInFile(path: string): Buffer[] {
	const read = readFileBytes(path);
	if (!read.ok) return [];
	const bytes = read.value;
	const text = bytes.asString();
	if (text.indexOf(BEGIN_MARKER) >= 0) return pemCertificates(text);
	if (isWholeDerSequence(bytes)) return [bytes];
	return [];
}

function addFile(anchors: TrustAnchor[], path: string): void {
	for (const der of certificatesInFile(path)) {
		anchors.push({ der, source: path });
	}
}

/**
 * The anchors of a file, or of every regular file in a directory (not
 * recursive). Empty when nothing loads.
 */
export function loadCaSource(path: string): TrustAnchor[] {
	const anchors: TrustAnchor[] = [];
	if (!isDir(path)) {
		addFile(anchors, path);
		return anchors;
	}
	const names = readDirNames(path);
	if (!names.ok) return anchors;
	for (const name of names.value) {
		const entry = join(path, name);
		if (isFile(entry)) addFile(anchors, entry);
	}
	return anchors;
}

function directoryOf(path: string): string {
	const cut = Math.max(path.lastIndexOf("\\"), path.lastIndexOf("/"));
	return cut < 0 ? "" : path.slice(0, cut + 1);
}

/** Windows: cacert.pem beside the executable, then in each PATH entry. */
export function windowsCaCandidates(
	executable: string,
	pathList: string,
): string[] {
	const candidates: string[] = [];
	const exeDir = directoryOf(executable);
	if (exeDir != "") candidates.push(exeDir + "cacert.pem");
	if (pathList == "") return candidates;
	for (const raw of pathList.split(";")) {
		let dir = raw;
		if (dir.length > 1 && dir.startsWith("\"") && dir.endsWith("\"")) {
			dir = dir.slice(1, dir.length - 1);
		}
		if (dir.length > 0) candidates.push(dir + "\\cacert.pem");
	}
	return candidates;
}

/** The fixed places this build's OS keeps its trust anchors, in order. */
export function systemCaCandidates(lookupEnv: EnvLookup): string[] {
	when (windows) {
		return windowsCaCandidates(execPath, lookupEnv("PATH"));
	}
	when (macos || ios) {
		return [...MACOS_CA_PATHS];
	}
	when (linux || android) {
		return [...LINUX_CA_PATHS];
	}
	return [...BSD_CA_PATHS];
}

function loaded(anchors: TrustAnchor[], source: string): RootStore {
	return { anchors, source };
}

/**
 * The trust anchors from `caPath` when given, else `$SSL_CERT_FILE`, else
 * `$SSL_CERT_DIR`, else the first candidate that exists and loads. A source
 * that was named but loads nothing is an error, not a fall-through.
 */
export function resolveRootStore(
	caPath: string | null,
	lookupEnv: EnvLookup,
	candidates: string[],
): Result<RootStore, CryptoError> {
	if (caPath != null) {
		const anchors = loadCaSource(caPath);
		if (anchors.length > 0) return Result.ok(loaded(anchors, caPath));
		return Result.err(rootStoreError(
			`failed to load CA certificates from ${caPath}`,
		));
	}
	for (const name of ["SSL_CERT_FILE", "SSL_CERT_DIR"]) {
		const path = lookupEnv(name);
		if (path == "") continue;
		const anchors = loadCaSource(path);
		if (anchors.length > 0) return Result.ok(loaded(anchors, path));
		return Result.err(rootStoreError(
			`no CA certificates found: ${name}=${path} did not load`,
		));
	}
	for (const path of candidates) {
		if (!exists(path)) continue;
		const anchors = loadCaSource(path);
		if (anchors.length > 0) return Result.ok(loaded(anchors, path));
	}
	return Result.err(rootStoreError(
		"no CA certificates found; set SSL_CERT_FILE or SSL_CERT_DIR",
	));
}

function processEnv(name: string): string {
	return env.get(name);
}

/** `resolveRootStore` against this process's environment and OS. */
export function loadRootStore(
	caPath: string | null,
): Result<RootStore, CryptoError> {
	return resolveRootStore(caPath, processEnv, systemCaCandidates(processEnv));
}

/**
 * The default root store, loaded on each call: a process-wide cache would
 * be module state shared across threads, and a Locked<T> payload cannot
 * own the anchors' memory.
 */
export function defaultRootStore(): Result<RootStore, CryptoError> {
	return loadRootStore(null);
}
