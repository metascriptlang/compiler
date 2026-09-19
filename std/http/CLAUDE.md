# std/http — HTTP/1.1 server and client

Feature-comparable to Node.js `http`, not API-identical: `Result<T, E>`, enums, `match` — a thin compatibility wrapper should be buildable on top.

## Module boundaries

| Module | Scope | Does NOT contain |
|---|---|---|
| `std/net/index.cms` | TCP socket primitives | HTTP parsing, protocol logic |
| `std/core/fetch/types.ms`, `errors.ms`, `headers.ms`, `parser.ms` | the definitions: enums + interfaces, error constructors, header get/set/has/serialize, request/response/URL/chunked parsing | socket I/O, server logic, any C |
| `std/core/fetch/client.cms` | connect / send / recv / body reading | server logic |
| `std/http/types.ms`, `errors.ms`, `headers.ms`, `parser.ms`, `client.ms` | re-export shims over `std/core/fetch/*` | definitions of their own |
| `std/http/server.cms` | bind / listen / accept / dispatch / streaming — the one file here with C (`@include`, `extern function`) | client logic |
| `std/http/multipart.ms` | multipart/form-data body builder, pure string construction | externs, imports |
| `std/http/index.ms` | re-exports, plus `std/core/websocket` | logic |

## Design rules

- **Pure MS where possible** — types, errors, headers and parser are `.ms` with no C, so they work on every backend.
- **`Result<T, HttpError>` everywhere** — no `throw`, no panics.
- **`int32` for fd / port / status** — sized integers, not `float64`.
- **`enum` for `HttpMethod` / `HttpErrorKind`** — native C switch, exhaustive `match`.
- **`match` for dispatch** — idiomatic MetaScript throughout.
- **Streaming first** — `writeHead` / `write` / `end` is the core API; `sendText` and friends are sugar on top.
- **Keep-alive by default** — the HTTP/1.1 behaviour Node.js has.
