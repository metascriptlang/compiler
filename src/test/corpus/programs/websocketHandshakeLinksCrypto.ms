// @stdout: s3pPLMBiTxaQ9kYGzzhZRbK+xOo= 129
// @skip-js: std/core/websocket has only a C backend (index.cms over runtime/crypto and std/net); there is no index.ms
// @skip-raiser: std/core/websocket has only a C backend (index.cms over runtime/crypto and std/net); there is no index.rms
import { deriveAcceptKey, buildUpgradeResponse } from "std/core/websocket";

const key = deriveAcceptKey("dGhlIHNhbXBsZSBub25jZQ==");
console.log(key, buildUpgradeResponse(key, "", []).length);
