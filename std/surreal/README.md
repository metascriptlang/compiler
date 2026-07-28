# surreal-ms

SurrealDB client for [MetaScript](https://metascript.dev), speaking the native
WebSocket + CBOR RPC protocol against SurrealDB v2 and v3 servers.

```ms
import { connectSurreal, Surreal } from "surreal";

interface Post { title: string; views: int32; }

function main(): void {
    const r = connectSurreal("ws://127.0.0.1:8000/rpc");
    if (!r.ok) { console.log(r.error.message); return; }
    const db = r.value;
    try db.signin("root", "root");
    try db.use("test", "blog");

    const posts = try Surreal.select<Post>(db, "posts");
    for (const p of posts) {
        console.log(p.title + " — " + p.views.toString() + " views");
    }
    db.close();
}
```

## Features

- **Native protocol** — WebSocket transport, CBOR wire format (binary, compact, schema-free).
- **Full v3 RPC parity** — every method in the SurrealDB v3 wire protocol surfaced as a typed wrapper: `select`, `create`, `update`, `merge`, `delete`, `insert`, `upsert`, `patch`, `relate`, `insertRelation`, `run`, `version`, `info`, `reset`, plus session + auth.
- **Typed CRUD** — `Surreal.select<Post>(...)`, `Surreal.findById<Post>(...)`, `Surreal.upsert<Post>(...)` decode server records directly into your struct via the `cborValueToStruct` macro. No manual field plucking.
- **Raw CRUD** — `selectRaw` / `createRaw` / etc. return untyped `CborValue` for dynamic-schema work, REPL inspection, or wrapping foreign tables.
- **Graph edges** — `relate<T>` and `insertRelation<T>` for typed graph construction; `recordId(table, id)` helper builds the RecordId Tag the wire requires.
- **SurrealQL queries** — `queryStr(sql)` and parameterised `query(sql, vars)`.
- **Live subscriptions** — `LIVE SELECT` over the same connection. Mixed-mode (live + regular RPC) works out of the box; pure-live mode just needs a background dispatch loop.
- **Session lifecycle** — `signin` / `signup` / `authenticate` / `invalidate` / `reset` / `letVar` / `unsetVar`.
- **Server introspection** — `version()`, `info()` for connection diagnostics.
- **Result<T, E>** error handling — no thrown exceptions on the happy path; every server/transport failure surfaces as a typed `SurrealError`.

## Installation

> The library is in early development. Until it lands on the package registry,
> consume it via local checkout or git pin in your `build.ms`.

Local clone:

```bash
git clone https://github.com/your-org/surreal-ms.git ~/.metascript/libs/surreal
```

`build.ms`:

```ms
import { defineBuild } from "std/build";

export const build = defineBuild({
    name: "myapp",
    entry: "src/main.ms",
    dependencies: {
        "surreal": "~/.metascript/libs/surreal",
    },
});
```

Then `import { connectSurreal } from "surreal"` resolves to the local checkout.

## Quick start

A fully runnable end-to-end smoke against a local server:

```ms
import { connectSurreal } from "surreal";
import { length, getDynamicField, asString } from "std/serialize/cbor/accessors";

function main(): void {
    const r = connectSurreal("ws://127.0.0.1:8000/rpc");
    if (!r.ok) { console.log("connect: " + r.error.message); return; }
    const c = r.value;

    if (!c.signin("root", "root").ok) { console.log("signin failed"); return; }
    if (!c.use("test", "test").ok)   { console.log("use failed");   return; }

    try c.queryStr("CREATE foo SET name = 'hello'");

    const rec = try c.queryStr("SELECT * FROM foo");
    console.log("records: " + rec.length().toString());

    c.close();
}
```

Boot the server first:

```bash
surreal start --user root --pass root memory
```

## Connecting

```ms
const r = connectSurreal("ws://127.0.0.1:8000/rpc");
if (!r.ok) { /* SurrealError */ return; }
const c = r.value;   // SurrealClient
```

`connectSurreal` opens a synchronous WebSocket and negotiates the `cbor`
subprotocol. If the server doesn't speak CBOR, the connection is closed and
an error returned — the client can't fall back to JSON.

| URL scheme | Result |
|---|---|
| `ws://host:port/rpc` | Plain WebSocket. Use for localhost or trusted networks. |
| `wss://host:port/rpc` | TLS-wrapped WebSocket. Use for production / cross-network. |

Always close the connection when done:

```ms
c.close();   // sends WebSocket close frame, drops the socket
```

`close()` is idempotent — calling it twice is safe.

## Authentication

| Function | Purpose |
|---|---|
| `c.signin(user, pass)` | Authenticate root or NS/DB user. Returns `Result<string, SurrealError>` — the JWT token. |
| `c.signup(creds)` | Sign up via SCOPE / ACCESS method. `creds` is a pre-built CBOR map containing the access-method-specific fields. Returns the JWT. |
| `c.authenticate(token)` | Re-authenticate with a previously-issued JWT (e.g. after reconnect). |
| `c.invalidate()` | Drop session auth (logout). Connection stays open; subsequent calls fall back to anonymous permissions. |

### Root signin

```ms
const tok = try c.signin("root", "root");
console.log("JWT length: " + tok.length.toString());
```

### Scoped signup

The shape of `creds` depends on your `DEFINE SCOPE` / `DEFINE ACCESS`
definition. Build it as a CBOR map:

```ms
import { cborText, cborTextMap } from "std/serialize/cbor/builder";

const creds = cborTextMap(
    ["NS", "DB", "AC", "email", "pass"],
    [
        cborText("test"),
        cborText("blog"),
        cborText("user"),
        cborText("alice@example.com"),
        cborText("hunter2"),
    ],
);
const jwt = try c.signup(creds);
```

## Selecting a namespace and database

Every connection starts namespace-less and database-less. Either authenticate
with credentials scoped to a namespace/database, or call `use` explicitly:

```ms
try c.use("production", "main");
```

## SurrealQL queries

The simplest form takes a query string:

```ms
const r = try c.queryStr("SELECT id, name FROM person WHERE age > 18");
// r is the raw response (Array of statement results).
```

For parameter bindings, use the `query` form and pre-build the vars map:

```ms
import { cborText, cborTextMap, cborInt } from "std/serialize/cbor/builder";

const vars = cborTextMap(
    ["minAge"],
    [cborInt(18 as int64)],
);
const r = try c.query("SELECT id, name FROM person WHERE age > $minAge", vars);
```

Bindings prevent SurrealQL injection and let the server reuse query plans.
Prefer `query` over string concatenation whenever user input flows into SQL.

### Inspecting results

`queryStr`/`query` return a raw `CborValue`. Surreal wraps results in
`[{ status, time, result }]` per statement. Walk it with the CBOR accessors:

```ms
import { at, length, getDynamicField, asString, asInt32 } from "std/serialize/cbor/accessors";

const r = try c.queryStr("SELECT name, age FROM person");
const stmt0 = r.at(0);                            // first statement
const rows  = getDynamicField(stmt0, "result");   // rows array
for (let i: int32 = 0 as int32; i < rows.length(); i = i + 1) {
    const row = rows.at(i);
    const name = getDynamicField(row, "name").asString();
    const age  = getDynamicField(row, "age").asInt32();
    console.log(name + " — " + age.toString());
}
```

If your rows are well-typed, prefer the typed CRUD facade described next.

## CRUD

There are two facades. Pick the one that matches your knowledge of the
response shape.

### Raw CRUD — returns `CborValue`

Use when the row shape is dynamic, foreign, or you want to inspect the result
manually before deciding what to do with it.

| Function | Purpose |
|---|---|
| `c.selectRaw(thing)` | Read a table or `table:id`. |
| `c.createRaw(thing, data)` | Create one record. |
| `c.updateRaw(thing, data)` | Replace records (full content). |
| `c.mergeRaw(thing, data)` | Merge fields into records (partial update). |
| `c.deleteRecordRaw(thing)` | Delete records, returns the deleted rows. |

```ms
const body = cborTextMap(
    ["title", "views"],
    [cborText("first"), cborInt(0 as int64)],
);
const created = try c.createRaw("posts", body);
// created.kind === CborKind.Array, holding the new record (with server-assigned id).
```

### Typed CRUD — `Surreal.select<T>`, `Surreal.create<T>`, …

Use when you have a struct/interface describing your rows. The
`cborValueToStruct` macro emits inline field-by-field decode at each
monomorphisation — no reflection, no boxing.

```ms
interface Post { title: string; body: string; views: int32; }

const all     = try Surreal.select<Post>(c, "posts");          // Post[]
const one     = try Surreal.create<Post>(c, "posts", body);    // Post
const merged  = try Surreal.merge<Post>(c, "posts", patchBody);// Post[]
const updated = try Surreal.update<Post>(c, "posts", newBody); // Post[]
const gone    = try Surreal.deleteRecord<Post>(c, "posts");    // Post[]
```

Constraints on `T`:

- **Struct or interface** with named fields. Atomic field types (string,
  number, sized ints, boolean) and nested named structs are supported.
- **`id` field omitted** — Surreal records carry an `id` as a RecordId
  (Tag-wrapped Map), which the V1.5 macro path cannot synthesise into a
  primitive. Drop it from your decode struct; if you need ids, decode via
  `*Raw` and inspect the Tag manually.
- **No array-of-struct fields** in the V1.5 macro path. If a row has a nested
  array of records, decode the wrapper as `Raw` and lift the inner array
  yourself, or wait for V2 of the codec.

## Single-record helpers

For "I know exactly which record I want" use `findById<T>`:

```ms
const p = try Surreal.findById<Post>(c, "posts:abc");
console.log(p.title);
```

Errors if no record matches (vs `select<T>` which returns an empty array).

For boolean existence checks, `exists` avoids decoding the body:

```ms
if (try c.exists("posts:abc")) {
    // record present
}
```

`exists` silently returns `false` when the table doesn't exist either —
matches "does the record exist" semantics rather than "did the query
succeed".

## Bulk operations

```ms
// insert(thing, data): bulk-create. `data` is a single map or array of maps.
const bulk = cborArray([
    cborTextMap(["title"], [cborText("p1")]),
    cborTextMap(["title"], [cborText("p2")]),
]);
const added = try Surreal.insert<Post>(c, "posts", bulk);
// added.length === 2
```

## Upsert (create-or-replace)

```ms
const body = cborTextMap(["title", "views"], [cborText("hello"), cborInt(0)]);
const p = try Surreal.upsert<Post>(c, "posts:hello", body);
// Creates posts:hello if absent, otherwise replaces it wholesale.
```

## Graph relations

Edges in Surreal are records on a relation table. Build them with `relate<T>`
— `from` and `to` MUST be RecordIds, built via `recordId(table, id)`:

```ms
interface Knows { weight: int64; }

const alice = recordId("peeps", "alice");
const bob   = recordId("peeps", "bob");
const data  = cborTextMap(["weight"], [cborInt(42 as int64)]);

const edge = try Surreal.relate<Knows>(c, alice, "knows", bob, data);
console.log("edge weight: " + edge.weight.toString());
```

For bulk edge insert, use `insertRelation<T>(table, data)` where `data` is a
map (or array of maps) carrying `in` / `out` RecordIds plus any edge fields:

```ms
const ir = try Surreal.insertRelation<Knows>(c, "knows", cborTextMap(
    ["in", "out", "weight"],
    [alice, bob, cborInt(7 as int64)],
));
```

## JSON Patch

`patch(thing, patches)` applies RFC 6902 operations atomically:

```ms
const patches = cborArray([
    cborTextMap(["op", "path", "value"], [cborText("replace"), cborText("/views"), cborInt(100 as int64)]),
    cborTextMap(["op", "path"],          [cborText("remove"),  cborText("/tempField")]),
]);
try c.patch("posts:abc", patches);
```

`patch("table:id", ...)` targets a single record; `patch("table", ...)`
applies the same operations to every row in the table.

Returned `CborValue` is the array of per-record JSON Patch result arrays —
the shape is too freeform for typed decode, inspect via CBOR accessors.

## Calling server-side functions

If you've defined functions in SurrealQL:

```sql
DEFINE FUNCTION fn::greet($who: string) {
    RETURN "hello " + $who;
};
```

Call them via `run`:

```ms
const args = cborArray([cborText("world")]);
const r = try c.run("fn::greet", args);
// r is a CborValue; for a string-returning fn use r.asString()
```

Works with built-in `fn::` functions and ML models (`ml::`) too. ML models
take a third `version` arg:

```ms
const r = try c.run("ml::sentiment", args, "v1.2.3");
```

## Server introspection

```ms
const v = try c.version();         // "surrealdb-3.0.5"
const i = try c.info();            // CborValue — auth-mode-dependent shape
try c.reset();                     // Clear session (auth, NS/DB, variables)
```

## Live subscriptions

Register a `LIVE SELECT` and receive notifications as records change:

```ms
import { CborKind, CborValue } from "std/serialize/cbor/types";
import { getDynamicField, asString } from "std/serialize/cbor/accessors";

const cb = (n: CborValue): void => {
    const action = getDynamicField(n, "action").asString();
    if (action === "CREATE") console.log("new row");
    if (action === "UPDATE") console.log("row changed");
    if (action === "DELETE") console.log("row gone");
};

const sub = try c.live("SELECT * FROM posts", cb);
// sub is the subscription UUID Tag — keep it to unsubscribe later.
```

### Mixed mode (live + regular RPC on same connection)

Just keep calling `query`/`select`/etc. — the underlying RPC loop drains
incoming frames and dispatches notifications inline as it goes. No extra
setup needed.

```ms
const sub = try c.live("SELECT * FROM posts", cb);
try c.queryStr("CREATE posts SET title = 'hello'");
// `cb` has already fired by the time queryStr returns.
```

### Subscribe-only mode

If your task does nothing but listen, drive the receive loop yourself in a
background task so notifications keep flowing while the main task blocks
elsewhere:

```ms
spawn(() => c.dispatchLoop());

// main task can now block on whatever (await, sleep, channel)
// and the spawned loop will keep delivering live notifications.
```

`c.dispatchLoop()` blocks reading frames and dispatching them until the
connection closes. `c.dispatchOnce()` is the single-step variant — reads
one frame, dispatches if it's a notification, returns `true` if it was.

### Stopping a subscription

```ms
try c.kill(sub);   // server stops sending; further frames are dropped
```

### Caveats

- **Callbacks run synchronously** on the RPC-driving thread. A slow callback
  stalls the original RPC's response delivery by the same amount. Keep them
  short — push heavy work onto a queue or `spawn` from inside the callback.
- **Table must exist** before `LIVE SELECT` on Surreal v3 — issue a no-op
  `CREATE` + `DELETE` first, or define the table explicitly. v2 doesn't
  have this constraint.
- `query` is concatenated as `"LIVE " + query` and sent verbatim. There is
  no parameterised LIVE form in the wire protocol — caller is trusted to
  pass safe SurrealQL.

## Error handling

Every public function returns `Result<T, SurrealError>`. The error carries a
discriminated `kind` plus a free-form message:

```ms
export enum SurrealErrorKind {
    ConnectionFailed,   // TCP / WebSocket transport failure
    Decode,             // server response is malformed or unexpected shape
    Rpc,                // server returned `{ error: { code, message } }`
    AuthFailed,         // signin / signup / authenticate rejected
    Closed,             // operation attempted on a closed client
    Internal,           // bug in the client itself — please file an issue
}
```

Branch on `kind` for fine-grained handling, or just propagate via the `try`
operator:

```ms
const r = c.signin(user, pass);
if (!r.ok) {
    if (r.error.kind === SurrealErrorKind.AuthFailed) {
        console.log("bad credentials");
    } else {
        console.log("transport error: " + r.error.message);
    }
    return;
}
const jwt = r.value;
```

`SurrealErrorKind.Rpc` also carries `rpcCode` (the server's numeric error
code) for fine-grained dispatch.

## Reconnection

The V0 client is connection-bound — there's no auto-reconnect. On
`ConnectionFailed` errors, you decide whether to retry, back off, or fail.
A typical pattern:

```ms
function withRetry<T>(f: () => Result<T, SurrealError>): Result<T, SurrealError> {
    let attempt = 0;
    while (attempt < 3) {
        const r = f();
        if (r.ok) return r;
        if (r.error.kind !== SurrealErrorKind.ConnectionFailed) return r;
        attempt = attempt + 1;
        // ...sleep with backoff...
    }
    return f();
}
```

## API reference

### Connection

```ms
function connectSurreal(url: string): Result<SurrealClient, SurrealError>;
function close(this c: SurrealClient): Result<void, SurrealError>;
function ping(this c: SurrealClient): Result<void, SurrealError>;
```

### Authentication

```ms
function signin(this c: SurrealClient, user: string, pass: string): Result<string, SurrealError>;
function signup(this c: SurrealClient, creds: CborValue): Result<string, SurrealError>;
function authenticate(this c: SurrealClient, token: string): Result<void, SurrealError>;
function invalidate(this c: SurrealClient): Result<void, SurrealError>;
```

### Session

```ms
function use(this c: SurrealClient, ns: string, db: string): Result<void, SurrealError>;
function letVar(this c: SurrealClient, key: string, value: CborValue): Result<void, SurrealError>;
function unsetVar(this c: SurrealClient, key: string): Result<void, SurrealError>;
```

### Queries

```ms
function queryStr(this c: SurrealClient, sql: string): Result<CborValue, SurrealError>;
function query(this c: SurrealClient, sql: string, vars: CborValue): Result<CborValue, SurrealError>;
```

### Raw CRUD

```ms
function selectRaw(this c: SurrealClient, thing: string): Result<CborValue, SurrealError>;
function createRaw(this c: SurrealClient, thing: string, data: CborValue): Result<CborValue, SurrealError>;
function updateRaw(this c: SurrealClient, thing: string, data: CborValue): Result<CborValue, SurrealError>;
function mergeRaw(this c: SurrealClient, thing: string, data: CborValue): Result<CborValue, SurrealError>;
function deleteRecordRaw(this c: SurrealClient, thing: string): Result<CborValue, SurrealError>;
function insertRaw(this c: SurrealClient, thing: string, data: CborValue): Result<CborValue, SurrealError>;
function upsertRaw(this c: SurrealClient, thing: string, data: CborValue): Result<CborValue, SurrealError>;
function relateRaw(this c: SurrealClient, from: CborValue, edge: string, to: CborValue, data: CborValue): Result<CborValue, SurrealError>;
function insertRelationRaw(this c: SurrealClient, table: string, data: CborValue): Result<CborValue, SurrealError>;
```

### Typed CRUD

```ms
class Surreal {
    static select<T>(c: SurrealClient, thing: string): Result<T[], SurrealError>;
    static findById<T>(c: SurrealClient, thing: string): Result<T, SurrealError>;
    static create<T>(c: SurrealClient, thing: string, data: CborValue): Result<T, SurrealError>;
    static update<T>(c: SurrealClient, thing: string, data: CborValue): Result<T[], SurrealError>;
    static merge<T>(c: SurrealClient, thing: string, data: CborValue): Result<T[], SurrealError>;
    static deleteRecord<T>(c: SurrealClient, thing: string): Result<T[], SurrealError>;
    static insert<T>(c: SurrealClient, thing: string, data: CborValue): Result<T[], SurrealError>;
    static upsert<T>(c: SurrealClient, thing: string, data: CborValue): Result<T, SurrealError>;
    static relate<T>(c: SurrealClient, from: CborValue, edge: string, to: CborValue, data: CborValue): Result<T, SurrealError>;
    static insertRelation<T>(c: SurrealClient, table: string, data: CborValue): Result<T, SurrealError>;
}
```

### Standalone RPCs

```ms
function patch(this c: SurrealClient, thing: string, patches: CborValue): Result<CborValue, SurrealError>;
function run(this c: SurrealClient, fn: string, args: CborValue, version: string = ""): Result<CborValue, SurrealError>;
function version(this c: SurrealClient): Result<string, SurrealError>;
function info(this c: SurrealClient): Result<CborValue, SurrealError>;
function reset(this c: SurrealClient): Result<void, SurrealError>;
function exists(this c: SurrealClient, thing: string): Result<boolean, SurrealError>;
function recordId(table: string, id: string): CborValue;
```

### Live subscriptions

```ms
function live(this c: SurrealClient, query: string, callback: (n: CborValue) => void): Result<CborValue, SurrealError>;
function kill(this c: SurrealClient, uuid: CborValue): Result<void, SurrealError>;
function dispatchOnce(this c: SurrealClient): Result<boolean, SurrealError>;
function dispatchLoop(this c: SurrealClient): Result<void, SurrealError>;
```

## CBOR helpers cheat-sheet

The client takes / returns `CborValue` for raw paths. These builders and
accessors are re-exported from `std/serialize/cbor`:

### Builders

```ms
cborText("hello")              // Text
cborInt(42 as int64)           // Int
cborFloat(3.14)                // Float
cborBool(true)                 // Bool
cborNull()                     // Null
cborTextMap(keys, values)      // Map with string keys
cborArray([v1, v2, ...])       // Array
cborTag(tagNum, inner)         // Tag (for RecordIds, UUIDs)
```

### Accessors (extension methods on `CborValue`)

```ms
v.asString(def?)               // Text → string
v.asInt32(def?) / asInt64(def?)// Int → int32 / int64
v.asNumber(def?)               // Float / Int → number
v.asBoolean(def?)              // Bool → boolean
v.length()                     // Array / Map length
v.at(i)                        // Array element by index
v.getDynamicField("k")         // Map value by key (auto-synthesised for `v.k`)
```

`getDynamicField` is the dynamic-property protocol — calling `v.foo` on a
`CborValue` is rewritten by the compiler into `v.getDynamicField("foo")`,
so map traversal reads naturally:

```ms
const title = row.title.asString();        // row.getDynamicField("title").asString()
const views = row.stats.daily.asInt32();   // chained dynamic field access
```

## Pre-requisites

A reachable SurrealDB v2 or v3 server. The simplest setup for local dev:

```bash
# Install once
curl -sSf https://install.surrealdb.com | sh

# Start an in-memory instance (data lost on exit)
surreal start --user root --pass root memory

# Or persistent on-disk
surreal start --user root --pass root file:./mydata
```

See the [SurrealDB install docs](https://surrealdb.com/docs/surrealdb/installation)
for production deployments.

## Known limitations

- **Sync only.** The V0 client blocks on every RPC. An async surface is
  planned; until then, wrap calls in `spawn` if you need parallelism.
- **One subscription per UUID.** The client tracks a flat list of
  subscriptions; `live()` returns the server's UUID Tag and you pass it back
  to `kill()`. Tagged dispatch is O(N) on the active subscription count.
- **No automatic reconnect.** A dropped connection surfaces as
  `ConnectionFailed` on the next RPC. Reconnect logic is the caller's
  responsibility.
- **Typed CRUD codec limits** (V1.5):
  - `id` field on Surreal records is a RecordId Tag — exclude it from your
    decode struct.
  - Array-of-struct fields are not yet supported by the macro path.
  - Union-typed fields are rejected at macro compile time.
- **No connection pooling.** One `SurrealClient` ≈ one socket. For a
  high-concurrency service, manage a pool of clients yourself.
- **`c.close()` may need explicit form.** When the WebSocket runtime is in
  scope, extension dispatch can pick `WsClient.close(code, reason)` instead
  of `SurrealClient.close()`. Workaround: call as a free function — `close(c)`
  instead of `c.close()`. Fix in the compiler dispatch path is queued.

## Roadmap

- Async surface — `await c.select<Post>(...)` over the same wire protocol.
- Auto-reconnect with subscription restore.
- Array-of-struct and union support in the typed-decode macro.
- Connection pool helper.

## Contributing

PRs welcome. Before submitting:

1. Run the test suite: `msc test src/test/surreal/index.ms`
2. Run the live-server smokes (require a running SurrealDB):

   ```bash
   surreal start --user root --pass root memory &
   msc run examples/wsSurreal.ms
   msc run examples/wsSurrealTyped.ms
   msc run examples/wsSurrealLive.ms
   msc run examples/wsSurrealAllOps.ms
   ```
3. Lint commit messages as `<type>: <description>` per Conventional Commits.

## License

MIT — see [`LICENSE`](./LICENSE).
