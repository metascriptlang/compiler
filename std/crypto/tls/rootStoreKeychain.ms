/**
 * The X.509 certificate records of a macOS keychain database file, read
 * straight from its bytes, with no Security framework call.
 */

import { Buffer } from "std/core/buffer";

export const MACOS_KEYCHAIN_PATHS: string[] = [
	"/System/Library/Keychains/SystemRootCertificates.keychain",
	"/Library/Keychains/System.keychain",
];

const X509_CERTIFICATE_TABLE: int64 = 0x80001000;
const SCHEMA_OFFSET_AT: int64 = 12;
const TABLE_HEADER_SIZE: int64 = 28;
const CERT_SIZE_AT: int64 = 16;
const CERT_HEADER_SIZE: int64 = 60;

function word(bytes: Readonly<uint8[]>, at: int64): int64 | null {
	if (at < 0 || at + 4 > (bytes.length as int64)) return null;
	return ((bytes[at] as int64) << 24) | ((bytes[at + 1] as int64) << 16) |
		((bytes[at + 2] as int64) << 8) | (bytes[at + 3] as int64);
}

function isKeychain(bytes: Readonly<uint8[]>): boolean {
	return bytes.length >= 20 && bytes[0] == "k".code &&
		bytes[1] == "y".code && bytes[2] == "c".code && bytes[3] == "h".code;
}

function tableCertificates(
	bytes: Readonly<uint8[]>,
	table: int64,
	out: Buffer[],
): void {
	const tableId = word(bytes, table + 4);
	const recordCount = word(bytes, table + 8);
	if (tableId != X509_CERTIFICATE_TABLE || recordCount == null) return;
	for (let i: int64 = 0; i < recordCount; i++) {
		const offset = word(bytes, table + TABLE_HEADER_SIZE + i * 4);
		if (offset == null) return;
		if (offset == 0 || offset % 4 != 0) continue;
		const record = table + offset;
		const size = word(bytes, record + CERT_SIZE_AT);
		if (size == null || size == 0) continue;
		const start = record + CERT_HEADER_SIZE;
		if (start + size > (bytes.length as int64)) continue;
		out.push(bytes.slice(start as number, (start + size) as number) as Buffer);
	}
}

/**
 * The DER certificates held in a keychain file's X.509 table. Empty when the
 * bytes are not a keychain; a record that runs past the end is skipped.
 */
export function keychainCertificates(bytes: Readonly<uint8[]>): Buffer[] {
	const out: Buffer[] = [];
	if (!isKeychain(bytes)) return out;
	const schema = word(bytes, SCHEMA_OFFSET_AT);
	if (schema == null) return out;
	const tableCount = word(bytes, schema + 4);
	if (tableCount == null) return out;
	for (let i: int64 = 0; i < tableCount; i++) {
		const tableOffset = word(bytes, schema + 8 + i * 4);
		if (tableOffset == null) return out;
		tableCertificates(bytes, schema + tableOffset, out);
	}
	return out;
}
