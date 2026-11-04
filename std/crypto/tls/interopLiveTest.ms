/**
 * native.ms against the openssl s_server matrix test/interop.sh starts. TLS_INTEROP_CASES lists
 * `name|host|ca|port|expect;` entries, `expect` being `ok <version> <suite or *> [hrr] [rekey] [alpn]`
 * or `err <text the error must contain>`; TLS_INTEROP_DIR holds `<ca>.pem`. Without them the test
 * connects nowhere and passes.
 */

import { env } from "std/process";
import { tlsConnect, TlsConnection, read, write, close } from "./native";
import { Tls13Client, updateKeys } from "./client";

function pageOf(conn: TlsConnection): string {
	if (conn.write("GET / HTTP/1.0\r\nHost: localhost\r\n\r\n") < 0) return "write: " + conn.lastError;
	let page = "";
	for (let i = 0; i < 64; i++) {
		const chunk = conn.read(16384);
		if (chunk.length == 0) break;
		for (const octet of chunk) page += String.fromCharCode(octet);
	}
	return page;
}

/** "" when the connection to `port` met `expect`, else what it did instead. */
function runCase(host: string, caPath: string, port: int32, expect: string): string {
	const words = expect.split(" ");
	const r = tlsConnect(host, port, { caPath, timeoutMs: 20000 });
	if (words[0] == "err") {
		if (r.ok) {
			r.value.close();
			return "connected, expected a refusal";
		}
		const wanted = expect.slice(4);
		return r.error.message.includes(wanted) ? "" : "refused with: " + r.error.message;
	}
	if (!r.ok) return "refused: " + r.error.message;
	const conn = r.value;
	const client = conn._client as Tls13Client;
	const version = client.version.toString(16).padStart(4, "0");
	const suite = client.cipherSuite.toString(16).padStart(4, "0");
	let problem = "";
	if (version != words[1]) problem += ` version ${version}`;
	if (words[2] != "*" && suite != words[2]) problem += ` suite ${suite}`;
	if (words.includes("hrr") != client.helloRetried) problem += ` helloRetried ${client.helloRetried}`;
	if (words.includes("alpn") && client.applicationProtocol != "http/1.1") problem += ` alpn "${client.applicationProtocol}"`;
	if (words.includes("rekey")) {
		const updated = client.updateKeys(true);
		if (!updated.ok) problem += " keyUpdate: " + updated.error.message;
	}
	const page = pageOf(conn);
	if (!page.includes("HTTP/1.0 200 ok")) problem += " page: " + page.slice(0, 60) + " " + conn.lastError;
	conn.close();
	return problem == "" ? "" : `suite ${suite}:${problem}`;
}

test "the openssl s_server interop matrix: every case connects or is refused as expected" {
	const cases = env.get("TLS_INTEROP_CASES");
	if (cases == "") {
		console.log("interop: skipped, TLS_INTEROP_CASES unset");
		return;
	}
	const dir = env.get("TLS_INTEROP_DIR");
	let passed = 0;
	let total = 0;
	for (const entry of cases.split(";")) {
		if (entry == "") continue;
		const fields = entry.split("|");
		total += 1;
		const started = Date.now();
		const problem = runCase(fields[1], `${dir}/${fields[2]}.pem`, parseInt(fields[3]) as int32, fields[4]);
		const took = Date.now() - started;
		if (problem == "") passed += 1;
		console.log(`interop ${problem == "" ? "PASS" : "FAIL"} ${fields[0]} (${took} ms)${problem == "" ? "" : ": " + problem}`);
	}
	console.log(`interop ${passed}/${total}`);
	assert passed == total;
}
