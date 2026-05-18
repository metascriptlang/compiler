# http-server bench

Five servers, same JSON endpoint, same hardware.

```
GET /users/<id>  ->  {"id":<id>,"name":"User <id>","email":"user<id>@example.com","created":1737000000}
```

## Results

t2a-standard-4 on GCP (4 vCPU Neoverse-N1, Ubuntu 24.04). `wrk -t4 -c200
-d30s`, median of 3 runs.

|             |   default | 4 procs   | RSS        |
| ----------- | --------: | --------: | ---------- |
| c           |   193,120 |        -  | 4.3M       |
| metascript  |   186,936 |        -  | 2.1M       |
| rust        |   182,726 |        -  | 2.3M       |
| bun         |    32,244 |    87,107 | 39M / 149M |
| node        |    17,098 |    46,633 | 47M / 233M |

C (libmicrohttpd thread pool), Rust (multi-thread tokio), and MetaScript
(`serveConcurrent`) use every core in their default config. Bun and Node
default to one process on one core; the `4 procs` column is the same code
spawned four times behind `SO_REUSEPORT` / `cluster`.

## Run it

ARM Linux box. Then:

```bash
sudo apt-get install -y wrk build-essential libmicrohttpd-dev
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
sudo apt-get install -y nodejs
curl -fsSL https://bun.sh/install | bash
curl -fsSL https://sh.rustup.rs | sh -s -- -y && source ~/.cargo/env

# Drop yyjson.h + yyjson.c (https://github.com/ibireme/yyjson) into c/.
gcc -O3 -flto -pthread -o c/c-server c/server.c c/yyjson.c -lmicrohttpd
(cd rust && cargo build --release)
msc build --release --strip metascript/server.ms --output=ms-server

# Default config, one at a time:
./c/c-server &       ; sleep 2 ; wrk -t4 -c200 -d30s http://127.0.0.1:8080/users/12345 ; pkill c-server
./ms-server &        ; sleep 2 ; wrk -t4 -c200 -d30s http://127.0.0.1:8080/users/12345 ; pkill ms-server
rust/target/release/server & ; sleep 2 ; wrk -t4 -c200 -d30s http://127.0.0.1:8080/users/12345 ; pkill server
bun run bun/server.ts &      ; sleep 2 ; wrk -t4 -c200 -d30s http://127.0.0.1:8080/users/12345 ; pkill bun
node node/server.js &        ; sleep 2 ; wrk -t4 -c200 -d30s http://127.0.0.1:8080/users/12345 ; pkill node

# Multi-process for bun / node:
for i in 1 2 3 4; do bun run bun/server-fork.ts & done
sleep 4 ; wrk -t4 -c200 -d30s http://127.0.0.1:8080/users/12345 ; pkill bun

WORKERS=4 node node/server-fork.js &
sleep 4 ; wrk -t4 -c200 -d30s http://127.0.0.1:8080/users/12345 ; pkill node
```

## Notes

Response body is 85 bytes, identical across all five. JSON encoded with each
language's idiomatic encoder (`yyjson`, `JSON.stringify<T>`, `serde`,
`JSON.stringify`).

MetaScript emits a `Date:` header on every response. Bun and Node default
configs don't. Node also uses chunked transfer encoding; the rest use
`Content-Length`. All valid HTTP/1.1.

`wrk` runs on the same machine as the server, so the load generator
competes for CPU. Same setup penalises every server equally and matches
Bun's own published benchmark methodology.

## License

MIT.
