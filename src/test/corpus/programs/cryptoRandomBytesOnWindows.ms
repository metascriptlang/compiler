// @stdout: ok 8 ok 64 distinct true
// @exit: 0
// @skip-js: std/crypto does not resolve on the JS target
// @skip-raiser
import { randomBytes } from "std/crypto";
const a = randomBytes(8);
const b = randomBytes(64);
const c = randomBytes(8);
const x = a.ok ? a.value.byteLength() : -1;
const y = b.ok ? b.value.byteLength() : -1;
const distinct = a.ok && c.ok && a.value != c.value;
console.log(`ok ${x} ok ${y} distinct ${distinct}`);
