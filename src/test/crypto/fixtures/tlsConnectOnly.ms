// Size consumer: a program whose only crypto is one TLS connection, built once over the public
// std/crypto/tls and once over the vendored binding (-d:cryptoImport=pure|native); it never connects
// unless given a host, so building it is the measurement.
import { argv } from "std/process";

when (cryptoImport == "pure") {
	import { tlsConnect, close } from "std/crypto/tls";
} else when (cryptoImport == "native") {
	import { tlsConnect, close } from "../oracle/tls";
}

const args = argv.slice(1);
if (args.length == 1) {
	const conn = tlsConnect(args[0], 443, { timeoutMs: 5000 });
	if (!conn.ok) throw new Error(conn.error.message);
	conn.value.close();
	console.log("connected");
} else {
	console.log("usage: tlsConnectOnly <host>");
}
