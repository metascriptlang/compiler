// @stdout: key 24 distinct true
// @exit: 0
// @skip-js: std/core/websocket is native-only
// @skip-raiser
import { makeClientKey } from "std/core/websocket/handshake";
const a = makeClientKey();
const b = makeClientKey();
console.log(`key ${a.length} distinct ${a != b}`);
