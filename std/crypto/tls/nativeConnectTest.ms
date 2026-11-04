/**
 * native.ms against live servers. TLS_NATIVE_DIR holds ca.pem (signs both
 * servers' leaves, SAN DNS:localhost) and other.pem (an unrelated CA);
 * TLS_NATIVE_PORT serves a valid leaf and TLS_NATIVE_EXPIRED_PORT an
 * expired one, both `openssl s_server -tls1_3 -www`, and TLS_NATIVE_TLS12_PORT
 * the valid leaf over `-tls1_2 -www`. TLS_NATIVE_PUBLIC=1
 * also connects to example.com:443 with the default root store. Without
 * the variables each test connects nowhere and passes.
 */

import { env } from "std/process";
import { tlsConnect, TlsConnection, read, write, close, peerCert, tlsClosedMessage } from "./native";
import { Tls13Client, versionTls12 } from "./client";

function localDir(): string {
	return env.get("TLS_NATIVE_DIR");
}

function portOf(name: string): int32 {
	return parseInt(env.get(name)) as int32;
}

function getPage(conn: TlsConnection, host: string): string {
	const sent = conn.write(`GET / HTTP/1.0\r\nHost: ${host}\r\n\r\n`);
	if (sent < 0) return "write: " + conn.lastError;
	let page = "";
	for (let i = 0; i < 64; i++) {
		const chunk = conn.read(16384);
		if (chunk.length == 0) break;
		for (const octet of chunk) page += String.fromCharCode(octet);
	}
	return page;
}

function refusal(host: string, port: int32, caPath: string): string {
	const r = tlsConnect(host, port, { caPath, timeoutMs: 20000 });
	if (r.ok) {
		r.value.close();
		return "connected";
	}
	return r.error.message;
}

test "a trusted localhost server serves its page and the connection closes once" {
	const dir = localDir();
	if (dir == "") {
		console.log("nativeConnect local: skipped, TLS_NATIVE_DIR unset");
		return;
	}
	const r = tlsConnect("localhost", portOf("TLS_NATIVE_PORT"), { caPath: `${dir}/ca.pem`, timeoutMs: 20000 });
	if (!r.ok) console.log("local connect: " + r.error.message);
	assert r.ok;
	const conn = r.value;
	console.log("local peerCert: " + conn.peerCert());
	assert conn.peerCert() == "CN=localhost";
	assert conn.write("") == 0;
	const page = getPage(conn, "localhost");
	console.log("local page: " + page.slice(0, 40));
	assert page.startsWith("HTTP/1.0 200");
	conn.close();
	conn.close();
	assert conn.read(16).length == 0 && conn.lastError == tlsClosedMessage;
	assert conn.write("x") == -1 && conn.lastError == tlsClosedMessage;
	assert conn.peerCert() == "";
}

test "a TLS 1.2-only server is negotiated down to 1.2 and verified" {
	const dir = localDir();
	if (dir == "") return;
	const r = tlsConnect("localhost", portOf("TLS_NATIVE_TLS12_PORT"), { caPath: `${dir}/ca.pem`, timeoutMs: 20000 });
	if (!r.ok) console.log("tls12 connect: " + r.error.message);
	assert r.ok;
	const conn = r.value;
	const client = conn._client as Tls13Client;
	console.log("tls12 version: " + client.version.toString(16) + " suite " + client.cipherSuite.toString(16));
	assert client.version == versionTls12;
	assert conn.peerCert() == "CN=localhost";
	const page = getPage(conn, "localhost");
	console.log("tls12 page: " + page.slice(0, 40));
	assert page.startsWith("HTTP/1.0 200");
	conn.close();
}

test "a certificate for another host name is refused" {
	const dir = localDir();
	if (dir == "") return;
	const message = refusal("127.0.0.1", portOf("TLS_NATIVE_PORT"), `${dir}/ca.pem`);
	console.log("wrong host: " + message);
	assert message.startsWith("certificate verification failed: ");
	assert message.includes("does not match");
}

test "a chain no trusted root signed is refused" {
	const dir = localDir();
	if (dir == "") return;
	const message = refusal("localhost", portOf("TLS_NATIVE_PORT"), `${dir}/other.pem`);
	console.log("untrusted CA: " + message);
	assert message.startsWith("certificate verification failed: ");
	assert message.includes("not correctly signed");
}

test "an expired leaf is refused" {
	const dir = localDir();
	if (dir == "") return;
	const message = refusal("localhost", portOf("TLS_NATIVE_EXPIRED_PORT"), `${dir}/ca.pem`);
	console.log("expired: " + message);
	assert message.startsWith("certificate verification failed: ");
	assert message.includes("expired");
}

test "a missing CA file and a closed port fail with the index's messages" {
	const dir = localDir();
	if (dir == "") return;
	const missing = refusal("localhost", portOf("TLS_NATIVE_PORT"), `${dir}/missing.pem`);
	assert missing == `failed to load CA certificates from ${dir}/missing.pem`;
	const closed = refusal("localhost", 1, `${dir}/ca.pem`);
	assert closed == "TCP connect to localhost failed";
}

test "example.com answers over the default root store when the host is online" {
	if (env.get("TLS_NATIVE_PUBLIC") != "1") {
		console.log("nativeConnect public: skipped, TLS_NATIVE_PUBLIC unset");
		return;
	}
	const r = tlsConnect("example.com", 443, { timeoutMs: 20000 });
	if (!r.ok && r.error.message.startsWith("TCP connect")) {
		console.log("nativeConnect public: skipped, offline: " + r.error.message);
		return;
	}
	if (!r.ok) console.log("public connect: " + r.error.message);
	assert r.ok;
	const conn = r.value;
	console.log("public peerCert: " + conn.peerCert());
	const page = getPage(conn, "example.com");
	console.log("public page: " + page.slice(0, 40));
	assert page.startsWith("HTTP/1.");
	conn.close();
}
