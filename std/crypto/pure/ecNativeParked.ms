// Red because of compiler card 2026-11-06-spread-of-a-module-const-array-races-on-worker-threads: importing a key copies
// the curve's OID with a spread of a module const, which corrupts memory when two threads run it (about 1 run in 9
// crashes on "value 8589934640 not in range"). Unregistered; the fixing session moves this test back into
// ecNativeTest.ms and deletes this file.

import { rfcP256Pem, rfcP384Pem, signAndVerify } from "./ecNativeTest";

test "a worker thread signs and verifies with the base tables on both curves" {
	const p256Task = spawn((): string => signAndVerify(rfcP256Pem, 32));
	const p384Task = spawn((): string => signAndVerify(rfcP384Pem, 48));
	assert await p256Task == "efd48b2aacb6a8fd1140dd9cd45e81d69d2c877b56aaf991c34d0ea84eaf3716f7cb1c942d657c41d436c7a1b6e29f65f3e900dbb9aff4064dc4ab2f843acda8";
	assert await p384Task == signAndVerify(rfcP384Pem, 48);
}
