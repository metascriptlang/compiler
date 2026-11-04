/**
 * `connectTls` against live `openssl s_server -www` instances on localhost.
 * Runs only when TLS12_LIVE_CASES lists `port=expected` pairs (comma
 * separated), where expected is the hex version and suite the handshake must
 * land on, e.g. `20001=303c02f`; without it the test connects nowhere and passes.
 */

import { env } from "std/process";
import { createSocket, connect, send, recv, close as closeSocket, setTimeout } from "std/net";
import { TlsTransport, connectTls, entropyLength, read, write, close } from "./client";

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

/** "version suite: page", or what failed. */
function fetchStatusPage(port: int32, seed: int32): string {
	const fd = createSocket();
	if (connect(fd, "127.0.0.1", port) != 0) return "connect failed";
	setTimeout(fd, 20000);
	const entropy = new Array<uint8>(entropyLength);
	for (let i = 0; i < entropyLength; i++) entropy[i] = ((i * 29 + seed * 11 + 3) & 255) as uint8;
	const connected = connectTls(new SocketTransport(fd), {
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
	const sent = client.write("GET / HTTP/1.0\r\n\r\n".asBytes().slice(0));
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
	return client.version.toString(16) + client.cipherSuite.toString(16) + " alpn=" + client.applicationProtocol + ": " + page;
}

test "live openssl s_server handshakes land on the expected version and suite" {
	const text = env.get("TLS12_LIVE_CASES");
	if (text == "") return;
	const cases = text.split(",");
	for (let i = 0; i < cases.length; i++) {
		const parts = cases[i].split("=");
		const port = parseInt(parts[0]) as int32;
		const result = fetchStatusPage(port, i);
		console.log("port " + parts[0] + " expects " + parts[1] + " -> " + result.slice(0, 160));
		assert result.startsWith(parts[1] + " ");
		assert result.includes("HTTP/1.0 200 ok");
	}
}
