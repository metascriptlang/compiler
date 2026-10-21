// @xfail(raiser): error: Cannot resolve module 'std/core/buffer'
// @stdout: 10 0 6 3
// @stdout: 1 2 5 3 1
// @stdout: 8 2 2 3
// @stdout: 4 3
import { Buffer as Bytes } from "std/core/buffer";

const json = "{\"a\":\"é\"}";
console.log(`${Buffer.byteLength(json)} ${Buffer.byteLength("")} ${Buffer.byteLength("a😀b")} ${Buffer.byteLength("hé", "bogus")}`);
console.log(`${Buffer.byteLength("abc", "hex")} ${Buffer.byteLength("abcd", "hex")} ${Buffer.byteLength("aGVsbG8", "base64")} ${Buffer.byteLength("aGVsb=", "base64")} ${Buffer.byteLength("YQ==", "base64url")}`);
console.log(`${Buffer.byteLength("hé😀", "utf16le")} ${Buffer.byteLength("hé", "latin1")} ${Buffer.byteLength("hé", "ascii")} ${Buffer.byteLength("hé", "utf8")}`);
const s = "x€";
console.log(`${Bytes.byteLength(s)} ${Bytes.fromArray([1, 2, 3]).byteLength()}`);
