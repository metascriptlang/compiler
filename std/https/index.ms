// std/https — HTTP/1.1 over TLS.
//
// Mirrors Node's `https` module. Same function names as `std/http` (no
// `Https` suffix); the distinction is the import path.
//
//   import { request } from "std/http";    // plain
//   import { request } from "std/https";   // TLS
//
// The TLS transport lives in std/core/fetch/tls.cms (co-located with the
// plain transport so the prelude `fetch()` can reach both via relative
// imports). This barrel just surfaces the TLS-forced request API.

export { request, requestWithRedirects } from "std/core/fetch/tls";
