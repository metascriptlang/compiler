// @stdout: ok 8 ok 64 distinct true
// @exit: 0
// @skip-js: std/crypto does not resolve on the JS target
// @skip-raiser
import { Buffer } from "std/core/buffer";
import { randomBytesSync } from "std/crypto";
const a = randomBytesSync(8);
const b = randomBytesSync(64);
const c = randomBytesSync(8);
const x = a.ok ? a.value.length : -1;
const y = b.ok ? b.value.length : -1;
const distinct = a.ok && c.ok && Buffer.compare(a.value, c.value) != 0;
console.log(`ok ${x} ok ${y} distinct ${distinct}`);
