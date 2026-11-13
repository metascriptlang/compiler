// Native .ms tlsConnect against the public mbedTLS tlsConnect: full handshake, then GET of a 1 MiB file,
// interleaved per round, median per server; then where the native record layer spends its time.
// Run through src/bench/crypto/vendor/tlsBench.sh, which starts the servers and sets TLS_BENCH_PORTS and TLS_BENCH_CA.

import { env } from "std/process";
import { tlsConnect as nativeConnect, read as nativeRead, write as nativeWrite, close as nativeClose } from "std/crypto/tls/native";
import { tlsConnect as vendorConnect, read as vendorRead, write as vendorWrite, close as vendorClose } from "../../../test/crypto/oracle/tls";
import { cipherSuiteOf, aeadSeal, aeadOpen, aeadTagLength, suiteAes128GcmSha256, suiteChacha20Poly1305Sha256 } from "std/crypto/tls/aead";
import {
	TrafficKeys, trafficKeysOf, sealRecords, openRecord, newRecordBuffer, append, takeRecord, recordNonce,
	recordHeader, contentApplicationData, maxPlaintextLength,
} from "std/crypto/tls/record";

const ROUNDS = 7;
const request = "GET /payload HTTP/1.0\r\n\r\n";
const payloadBytes = 1 << 20;

function median(xs: number[]): number {
	const sorted = [...xs];
	sorted.sort((a, b) => a - b);
	return sorted[sorted.length >> 1];
}

interface Sample {
	handshakeMs: number;
	transferMs: number;
}

function nativeRun(port: int32, ca: string): Sample {
	const started = performance.now();
	const r = nativeConnect("localhost", port, { caPath: ca, timeoutMs: 20000 });
	if (!r.ok) throw new Error("native connect: " + r.error.message);
	const conn = r.value;
	const connected = performance.now();
	nativeWrite(conn, request);
	let total: number = 0;
	while (true) {
		const chunk = nativeRead(conn, 16384);
		if (chunk.length == 0) break;
		total += chunk.length;
	}
	const done = performance.now();
	nativeClose(conn);
	if (total < payloadBytes) throw new Error(`native read ${total} bytes: ${conn.lastError}`);
	return { handshakeMs: connected - started, transferMs: done - connected };
}

function vendorRun(port: int32, ca: string): Sample {
	const started = performance.now();
	const r = vendorConnect("localhost", port, { caPath: ca, timeoutMs: 20000 });
	if (!r.ok) throw new Error("mbedTLS connect: " + r.error.message);
	const conn = r.value;
	const connected = performance.now();
	vendorWrite(conn, request);
	let total: number = 0;
	while (true) {
		const chunk = vendorRead(conn, 16384);
		if (chunk.length == 0) break;
		total += chunk.length;
	}
	const done = performance.now();
	vendorClose(conn);
	if (total < payloadBytes) throw new Error(`mbedTLS read ${total} bytes: ${conn.lastError}`);
	return { handshakeMs: connected - started, transferMs: done - connected };
}

function fixed(value: number): string {
	return (Math.round(value * 100) / 100).toString();
}

const ca = env.get("TLS_BENCH_CA");
const ports = env.get("TLS_BENCH_PORTS");
if (ports != "") {
	console.log("server | native handshake ms | mbedTLS handshake ms | native MiB/s | mbedTLS MiB/s");
	for (const entry of ports.split(",")) {
		const parts = entry.split("=");
		const port = parseInt(parts[1]) as int32;
		const native: Sample[] = [];
		const vendor: Sample[] = [];
		for (let round = 0; round < ROUNDS; round++) {
			native.push(nativeRun(port, ca));
			vendor.push(vendorRun(port, ca));
		}
		const nativeHandshake = median(native.map((s) => s.handshakeMs));
		const vendorHandshake = median(vendor.map((s) => s.handshakeMs));
		const nativeRate = 1000 / median(native.map((s) => s.transferMs));
		const vendorRate = 1000 / median(vendor.map((s) => s.transferMs));
		console.log(`${parts[0]} | ${fixed(nativeHandshake)} | ${fixed(vendorHandshake)} | ${fixed(nativeRate)} | ${fixed(vendorRate)}`);
	}
}

// Record layer split: 1 MiB through the bare AEAD, through sealRecords, and through RecordBuffer plus openRecord.
function keysFor(code: int32): TrafficKeys {
	const suite = cipherSuiteOf(code);
	if (suite == null) throw new Error("suite");
	const secret = new Array<uint8>(32);
	secret[0] = 9;
	return trafficKeysOf(suite, secret);
}

function timed(op: () => void): number {
	const samples: number[] = [];
	for (let round = 0; round < ROUNDS; round++) {
		const started = performance.now();
		op();
		samples.push(performance.now() - started);
	}
	return median(samples);
}

const data = new Array<uint8>(payloadBytes);
for (let i = 0; i < payloadBytes; i++) data[i] = (i * 7) as uint8;
console.log("suite | bare AEAD seal ms | sealRecords ms | bare AEAD open ms | buffer+openRecord ms (per MiB)");
for (const code of [suiteAes128GcmSha256, suiteChacha20Poly1305Sha256]) {
	const keys = keysFor(code);
	const header = recordHeader(contentApplicationData, maxPlaintextLength + 1 + aeadTagLength);
	const chunk = data.slice(0, maxPlaintextLength);
	const records = payloadBytes / maxPlaintextLength;
	const bareSeal = timed(() => {
		for (let i = 0; i < records; i++) aeadSeal(keys.key, recordNonce(keys.iv, i as uint64), header, chunk);
	});
	let wire: uint8[] = [];
	const layered = timed(() => {
		const writer = keysFor(code);
		const sealed = sealRecords(writer, contentApplicationData, data);
		if (!sealed.ok) throw new Error("seal");
		wire = sealed.value;
	});
	const one = aeadSeal(keys.key, recordNonce(keys.iv, 0), header, chunk);
	const bareOpen = timed(() => {
		for (let i = 0; i < records; i++) aeadOpen(keys.key, recordNonce(keys.iv, 0), header, one);
	});
	const opened = timed(() => {
		const reader = keysFor(code);
		const buffer = newRecordBuffer();
		for (let at = 0; at < wire.length; at += 16389) buffer.append(wire.slice(at, Math.min(at + 16389, wire.length) as int32));
		while (true) {
			const record = buffer.takeRecord();
			if (record == null) break;
			if (!openRecord(reader, record).ok) throw new Error("open");
		}
	});
	console.log(`${code.toString(16)} | ${fixed(bareSeal)} | ${fixed(layered)} | ${fixed(bareOpen)} | ${fixed(opened)}`);
}
