import {
	appendTransactionMessageInstruction,
	createKeyPairSignerFromPrivateKeyBytes,
	createTransactionMessage,
	lamports,
	pipe,
	setTransactionMessageFeePayerSigner,
	setTransactionMessageLifetimeUsingBlockhash,
	signTransactionMessageWithSigners,
} from "@solana/kit";
import { LiteSVM } from "litesvm";

const [programPath] = process.argv.slice(2);
if (!programPath) {
	console.error("usage: node pow.mjs <powProbe.so>   (msc build tools/solana/powProbe.ms --os=solana --release --output=powProbe.so)");
	process.exit(2);
}

const svm = new LiteSVM();
const program = (await createKeyPairSignerFromPrivateKeyBytes(new Uint8Array(32).fill(9))).address;
svm.addProgramFromFile(program, programPath);
const payer = await createKeyPairSignerFromPrivateKeyBytes(new Uint8Array(32).fill(1));
svm.airdrop(payer.address, lamports(10_000_000_000n));

let failures = 0;
function check(what, condition) {
	console.log(`${what}: ${condition ? "ok" : "FAILED"}`);
	if (!condition) failures++;
}

async function run(op, at) {
	const message = pipe(
		createTransactionMessage({ version: 0 }),
		(m) => setTransactionMessageFeePayerSigner(payer, m),
		(m) => setTransactionMessageLifetimeUsingBlockhash({ blockhash: svm.latestBlockhash(), lastValidBlockHeight: 1000n }, m),
		(m) => appendTransactionMessageInstruction({ programAddress: program, accounts: [], data: Uint8Array.from([op, at]) }, m),
	);
	const result = svm.sendTransaction(await signTransactionMessageWithSigners(message));
	svm.expireBlockhash();
	const failed = result.constructor.name === "FailedTransactionMetadata";
	const meta = failed ? result.meta() : result;
	const logs = meta.logs().filter((l) => l.startsWith("Program log:"));
	return { ok: !failed, error: failed ? result.err().toString() : "", logs, units: meta.computeUnitsConsumed() };
}

const bitsOf = (v) => new BigUint64Array(new Float64Array([Number.isNaN(v) ? NaN : v]).buffer)[0];
const ulps = (got, want) => {
	if (Number.isNaN(want)) return got === 0x7ff8000000000000n ? 0n : -1n;
	const signed = (b) => (b >> 63n ? -(b & 0x7fffffffffffffffn) : b);
	const d = signed(got) - signed(bitsOf(want));
	return d < 0n ? -d : d;
};

const xs = [2, 3, 0.3, 1.1, 7, 49.283038373705544, 1e-300, 1e300, 0, -0, -8, 1, -1, Infinity, -Infinity, NaN, 10, Math.PI];
const ys = [0.5, 1.5, 37, 37, -0.5, 1.5, 0.5, -0.5, -0.5, -0.5, 1 / 3, NaN, Infinity, -0.5, 1.5, 0, -1074, Math.E];
const ops = [["x ** 1.5", (x) => x ** 1.5], ["x ** 37", (x) => x ** 37], ["x ** -0.5", (x) => x ** -0.5], ["Math.pow(x, y)", (x, y) => Math.pow(x, y)]];
let exact = 0, near = 0, maxUnits = 0;
for (const [op, [name, f]] of ops.entries()) {
	for (const [at, x] of xs.entries()) {
		const want = f(x, ys[at]);
		const outcome = await run(op, at);
		const got = outcome.ok && outcome.logs.length === 1 ? BigInt(outcome.logs[0].slice("Program log: ".length)) : null;
		const off = got === null ? -1n : ulps(got, want);
		if (off === 0n) exact++;
		else if (off === 1n) near++;
		if (outcome.units > maxUnits) maxUnits = outcome.units;
		if (off < 0n || off > 1n) check(`[${name}, x = ${Object.is(x, -0) ? "-0" : x}${op === 3 ? `, y = ${ys[at]}` : ""}] gives node's ${want} to 1 ulp (${outcome.ok ? `got bits ${got?.toString(16)}` : outcome.error})`, false);
	}
}
console.log(`${exact} exact, ${near} within 1 ulp, of ${ops.length * xs.length}; most units ${maxUnits}`);
check("every power is node's to 1 ulp", failures === 0);

if (failures > 0) {
	console.log(`${failures} FAILED`);
	process.exit(1);
}
console.log("all ok");
