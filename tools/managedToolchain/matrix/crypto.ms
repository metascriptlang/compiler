import { sha256Sync, sha512Sync, hmacSync, toHex } from "std/crypto";

const abc = sha256Sync("abc");
const long = sha512Sync("matrix");
const mac = hmacSync("sha256", "key", "message");
if (!abc.ok || !long.ok || !mac.ok) { throw new Error("crypto failed"); }
console.log("matrix-crypto", toHex(abc.value), toHex(long.value).slice(0, 32), toHex(mac.value));
