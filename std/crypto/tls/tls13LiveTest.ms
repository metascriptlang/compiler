/**
 * The TLS 1.3 client against a live `openssl s_server -www` on localhost.
 * Runs only when TLS13_LIVE_PORTS lists the servers' ports (comma
 * separated); without it the test connects nowhere and passes.
 */

import { env } from "std/process";
import { createSocket, connect, send, recv, close as closeSocket, setTimeout } from "std/net";
import { TlsTransport, connectTls13, entropyLength, read, write, close, updateKeys } from "./client";

class SocketTransport extends TlsTransport {
	fd: int32;

	constructor(fd: int32) {
		super();
		this.fd = fd;
	}

	receive(maxBytes: int32): uint8[] {
		const chunk: uint8[] = recv(this.fd, maxBytes);
		return chunk;
	}

	send(data: Readonly<uint8[]>): boolean {
		const bytes: uint8[] = [...data];
		return send(this.fd, bytes) == bytes.length;
	}
}

/** Test only: the servers present throwaway self-signed certificates, so the chain is not checked here. */
function acceptAnyChain(chain: uint8[][], hostname: string): Result<void, string> {
	if (chain.length == 0) return Result.err("empty chain");
	return Result.ok(null);
}

function livePorts(): int32[] {
	const text = env.get("TLS13_LIVE_PORTS");
	const out: int32[] = [];
	if (text == "") return out;
	for (const part of text.split(",")) out.push(parseInt(part) as int32);
	return out;
}

function fetchStatusPage(port: int32, seed: int32, rekey: boolean): string {
	const fd = createSocket();
	if (connect(fd, "127.0.0.1", port) != 0) return "connect failed";
	setTimeout(fd, 20000);
	const entropy = new Array<uint8>(entropyLength);
	for (let i = 0; i < entropyLength; i++) entropy[i] = ((i * 31 + seed * 7 + 1) & 255) as uint8;
	const connected = connectTls13(new SocketTransport(fd), {
		hostname: "localhost",
		verifier: acceptAnyChain,
		entropy,
		alpn: ["http/1.1"],
	});
	if (!connected.ok) {
		closeSocket(fd);
		return "handshake: " + connected.error.message;
	}
	const client = connected.value;
	if (rekey) {
		const updated = client.updateKeys(true);
		if (!updated.ok) return "keyUpdate: " + updated.error.message;
	}
	const request = "GET / HTTP/1.0\r\n\r\n".asBytes().slice(0);
	const sent = client.write(request);
	if (!sent.ok) return "write: " + sent.error.message;
	let page = "";
	while (true) {
		const chunk = client.read();
		if (!chunk.ok) {
			if (page.length > 0 && chunk.error.message == "TlsConnectionTruncated") break;
			return "read: " + chunk.error.message;
		}
		if (chunk.value.length == 0) break;
		for (const octet of chunk.value) page += String.fromCharCode(octet);
	}
	client.close();
	closeSocket(fd);
	const retried = client.helloRetried ? " after HelloRetryRequest" : "";
	return "suite " + client.cipherSuite.toString(16) + retried + ": " + page;
}

test "live openssl s_server handshakes, one per configured port" {
	const ports = livePorts();
	for (let i = 0; i < ports.length; i++) {
		const result = fetchStatusPage(ports[i], i, i == 0);
		console.log("port " + String(ports[i]) + " -> " + result.slice(0, 200));
		assert result.startsWith("suite ");
		assert result.includes("HTTP/1.0 200 ok");
	}
}
