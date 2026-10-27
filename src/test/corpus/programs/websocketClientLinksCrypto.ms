// @stdout: s3pPLMBiTxaQ9kYGzzhZRbK+xOo= 2
// @skip-js: std/core/websocket has only a C backend (index.cms over runtime/crypto and std/net); there is no index.ms
// @skip-raiser: std/core/websocket has only a C backend (index.cms over runtime/crypto and std/net); there is no index.rms
import { deriveAcceptKey, stringToBytes } from "std/core/websocket";

console.log(deriveAcceptKey("dGhlIHNhbXBsZSBub25jZQ=="), stringToBytes("ab").length);
