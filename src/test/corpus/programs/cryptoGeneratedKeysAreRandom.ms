// @stdout: ed25519 64 distinct true x25519 32 distinct true
// @exit: 0
// @skip-js: std/crypto has only a C backend; there is no .jms
// @skip-raiser: the raiser std/crypto carries only the string-encoded hash family
import { Buffer } from "std/core/buffer";
import { ed25519Generate } from "std/crypto/ed25519";
import { x25519Generate } from "std/crypto/x25519";

const signA = ed25519Generate();
const signB = ed25519Generate();
const dhA = x25519Generate();
const dhB = x25519Generate();
const signLength = signA.ok ? signA.value.length : -1;
const dhLength = dhA.ok ? dhA.value.length : -1;
const signDistinct = signA.ok && signB.ok && Buffer.compare(signA.value, signB.value) != 0;
const dhDistinct = dhA.ok && dhB.ok && Buffer.compare(dhA.value, dhB.value) != 0;
console.log(`ed25519 ${signLength} distinct ${signDistinct} x25519 ${dhLength} distinct ${dhDistinct}`);
