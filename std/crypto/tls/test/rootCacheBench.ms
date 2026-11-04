// Connect time (handshake + close) with roots loaded per connect vs held, interleaved per round, medians.
// BENCH_BIG: the system bundle plus the test CA; BENCH_SMALL: the test CA alone; BENCH_PORT: s_server -tls1_3 -www.

import { env } from "std/process";
import { tlsConnect, trustedRoots, TlsOptions, close } from "../native";

const ROUNDS = 40;

function median(xs: number[]): number {
	const sorted = [...xs];
	sorted.sort((a, b) => a - b);
	return sorted[sorted.length >> 1];
}

function connectMs(port: int32, opts: TlsOptions): number {
	const started = performance.now();
	const r = tlsConnect("localhost", port, opts);
	const took = performance.now() - started;
	if (!r.ok) throw new Error("connect: " + r.error.message);
	r.value.close();
	return took;
}

const port = parseInt(env.get("BENCH_PORT")) as int32;
const big = env.get("BENCH_BIG");
const small = env.get("BENCH_SMALL");
const bigRoots = trustedRoots(big);
const smallRoots = trustedRoots(small);
if (!bigRoots.ok || !smallRoots.ok) throw new Error("roots did not load");
console.log(`big bundle roots: ${bigRoots.value.certificates.length}`);
const rows: number[][] = [[], [], [], [], []];
for (let i = 0; i < ROUNDS; i++) {
	rows[0].push(connectMs(port, { caPath: big }));
	rows[1].push(connectMs(port, { roots: bigRoots.value }));
	rows[2].push(connectMs(port, { caPath: small }));
	rows[3].push(connectMs(port, { roots: smallRoots.value }));
	const started = performance.now();
	const fresh = trustedRoots();
	rows[4].push(performance.now() - started);
	if (!fresh.ok) throw new Error("default store: " + fresh.error.message);
}
const names = ["system-size caPath per connect", "system-size roots held", "1-root caPath per connect", "1-root roots held", "trustedRoots() default store alone"];
for (let i = 0; i < names.length; i++) console.log(`${names[i]}: ${median(rows[i]).toFixed(3)} ms`);
