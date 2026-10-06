import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import {
	AccountRole,
	address,
	appendTransactionMessageInstruction,
	createKeyPairSignerFromPrivateKeyBytes,
	createTransactionMessage,
	getAddressEncoder,
	lamports,
	pipe,
	setTransactionMessageFeePayerSigner,
	setTransactionMessageLifetimeUsingBlockhash,
	signTransactionMessageWithSigners,
} from "@solana/kit";
import { Clock, LiteSVM } from "litesvm";

const [programPath] = process.argv.slice(2);
if (!programPath) {
	console.error("usage: node heapExhausted.mjs <heapProbe.so>   (msc build tools/solana/heapProbe.ms --os=solana --output=heapProbe.so)");
	process.exit(2);
}

const HEAP = 32 * 1024;
const BUDGET = 1_400_000;
const LARGEST_COUNT = 60_000;
const NAMED = /std\/solana: the (\d+) KiB program heap is exhausted \(asked (\d+) more bytes at (\d+)\)/;
const OPS = { seeds: 1, builders: 2, cells: 3, request: 4, wrap: 5, push: 6, literal: 7, pairs: 8, text: 9, signed: 10, unsigned: 11, limits: 13, rent: 14, clock: 15, returnData: 16, logKey: 17, event: 18, wide: 19, fullReturn: 20 };
const MASK = 2n ** 64n - 1n;
const SUMS = {
	push: (n) => sum(n, (i) => (3n * i + 1n) * (i + 1n)),
	literal: (n) => sum(n, (i) => 10n * i + 20n),
	pairs: (n) => sum(n, (i) => 7n * i + 2n * i + 1n),
	text: (n) => 2n * n + sum(n, () => 97n + 98n * 3n),
};
const LOGGED = /^Program log: 0x[0-9a-f]+, 0x[0-9a-f]+, 0x[0-9a-f]+, 0x[0-9a-f]+, 0x([0-9a-f]+)$/;

const svm = new LiteSVM();
const program = (await createKeyPairSignerFromPrivateKeyBytes(new Uint8Array(32).fill(9))).address;
svm.addProgramFromFile(program, programPath);
const payer = await createKeyPairSignerFromPrivateKeyBytes(new Uint8Array(32).fill(1));
svm.airdrop(payer.address, lamports(10_000_000_000n));
const budget = new Uint8Array(5);
budget[0] = 2;
new DataView(budget.buffer).setUint32(1, BUDGET, true);

let failures = 0;

function sum(count, term) {
	let total = 0n;
	for (let i = 0n; i < count; i++) total += term(i);
	return total & MASK;
}

function check(what, condition) {
	console.log(`${what}: ${condition ? "ok" : "FAILED"}`);
	if (!condition) failures++;
}

check("the host simulator says the same thing",
	readFileSync(new URL("../../runtime/solana/host.c", import.meta.url), "utf8")
		.includes("the 32 KiB program heap is exhausted (asked %llu more bytes at %llu)"));

async function run(op, count, accounts = [program]) {
	const message = pipe(
		createTransactionMessage({ version: 0 }),
		(m) => setTransactionMessageFeePayerSigner(payer, m),
		(m) => setTransactionMessageLifetimeUsingBlockhash({ blockhash: svm.latestBlockhash(), lastValidBlockHeight: 1000n }, m),
		(m) => appendTransactionMessageInstruction({ programAddress: address("ComputeBudget111111111111111111111111111111"), accounts: [], data: budget }, m),
		(m) => appendTransactionMessageInstruction({
			programAddress: program,
			accounts: accounts.map((key) => ({ address: key, role: AccountRole.READONLY })),
			data: new Uint8Array([op, count & 0xff, count >> 8]),
		}, m),
	);
	const result = svm.sendTransaction(await signTransactionMessageWithSigners(message));
	svm.expireBlockhash();
	const failed = result.constructor.name === "FailedTransactionMetadata";
	const meta = failed ? result.meta() : result;
	const logs = meta.logs();
	const named = logs.map((line) => NAMED.exec(line)).find((found) => found !== undefined && found !== null) ?? null;
	const found = logs.map((line) => LOGGED.exec(line)).filter((entry) => entry !== null);
	return {
		value: found.length === 0 ? null : BigInt(`0x${found[found.length - 1][1]}`),
		first: found.length === 0 ? null : BigInt(`0x${found[0][1]}`),
		ok: !failed,
		error: failed ? result.err().toString() : "",
		units: Number(meta.computeUnitsConsumed()),
		logs,
		named,
	};
}

async function firstFailure(op) {
	if ((await run(op, LARGEST_COUNT)).ok) return null;
	let passes = 0;
	let fails = LARGEST_COUNT;
	while (fails - passes > 1) {
		const middle = Math.floor((passes + fails) / 2);
		if ((await run(op, middle)).ok) passes = middle;
		else fails = middle;
	}
	return fails;
}

function namedFailure(label, outcome) {
	check(`${label}: the instruction fails`, !outcome.ok && outcome.error.includes("ProgramFailedToComplete"));
	check(`${label}: the log names the exhausted heap`, outcome.named !== null);
	check(`${label}: the failure is not an access violation`, !outcome.logs.some((line) => /Access violation|Overlapping copy/.test(line)));
	check(`${label}: ${outcome.units} CU, not the whole ${BUDGET} budget`, outcome.units < BUDGET);
	if (outcome.named === null) return null;
	const [, kib, asked, position] = outcome.named;
	check(`${label}: the log states the heap size (${kib} KiB)`, Number(kib) * 1024 === HEAP);
	return { asked: BigInt(asked), position: BigInt(position) };
}

{
	const name = "account table";
	const others = [];
	for (let seed = 0; seed < 30; seed++) others.push((await createKeyPairSignerFromPrivateKeyBytes(new Uint8Array(32).fill(100 + seed))).address);
	const listOf = (total) => Array.from({ length: total }, (_, at) => (at === 0 ? program : others[(at - 1) % others.length]));
	const single = await run(OPS.request, 0);
	check(`[${name}] one account runs and logs the heap position ${single.value}`, single.ok && single.value !== null);
	for (const total of [2, 17, 64, 255]) {
		const outcome = await run(OPS.request, 0, listOf(total));
		check(`[${name}] ${total} accounts leave the heap position at ${single.value} (${outcome.ok ? "" : `${outcome.error}, `}${outcome.value})`,
			outcome.ok && outcome.value === single.value);
	}
}

{
	const name = "seeds";
	const single = await run(OPS.seeds, 1);
	check(`[${name}] a single round runs`, single.ok);
	for (const count of [2, 163, 164, 500]) {
		const outcome = await run(OPS.seeds, count);
		check(`[${name}] ${count} rounds run and leave the heap position at ${single.value} (${outcome.ok ? `${outcome.units} CU` : outcome.error})`,
			outcome.ok && outcome.value === single.value);
	}
	const first = await firstFailure(OPS.seeds);
	check(`[${name}] some count runs out of compute`, first !== null);
	if (first !== null) {
		const last = await run(OPS.seeds, first - 1);
		check(`[${name}] ${first - 1} rounds still run, ${last.units} CU, heap position unchanged`, last.ok && last.value === single.value);
		const failed = await run(OPS.seeds, first);
		check(`[${name}] ${first} rounds fail on the compute budget, not on the heap`,
			!failed.ok && failed.named === null && /ComputationalBudgetExceeded|exceeded CUs meter/.test(`${failed.error}\n${failed.logs.join("\n")}`));
	}
}

{
	const name = "cpi";
	const base = (await run(OPS.seeds, 1)).value;
	const units = new Map();
	for (const [kind, op] of [["unsigned", OPS.unsigned], ["signed", OPS.signed], ["builders", OPS.builders]]) {
		for (const count of [1, 2, 8, 20, 40]) {
			const outcome = await run(op, count);
			units.set(`${kind}${count}`, outcome.units);
			check(`[${name}] ${count} ${kind} CPIs run and leave the heap position at ${base} (${outcome.ok ? `${outcome.units} CU` : outcome.error})`,
				outcome.ok && outcome.value === base);
		}
	}
	check(`[${name}] a signer of sixteen seeds is sent`, (await run(OPS.limits, 0)).ok);
	for (const [count, what] of [[1, "seventeen seeds"], [2, "a seed of thirty-three bytes"]]) {
		const refused = await run(OPS.limits, count);
		check(`[${name}] a signer of ${what} fails the CPI (${refused.error})`,
			!refused.ok && /MaxSeedLengthExceeded|Max seed length exceeded|Length of the seed is too long/i.test(`${refused.error}\n${refused.logs.join("\n")}`));
	}
	for (const count of [1, 16, 17, 63, 64]) {
		const listed = await run(OPS.wide, count);
		check(`[${name}] a run-time list of ${count} accounts is sent (${listed.ok ? `${listed.units} CU` : listed.error})`, listed.ok);
	}
	const beyond = await run(OPS.wide, 65);
	check(`[${name}] a run-time list of 65 accounts is refused with InvalidArgument before it is sent (${beyond.error})`,
		!beyond.ok && /InvalidArgument/.test(beyond.error));
	const perCall = (kind) => Math.round((units.get(`${kind}20`) - units.get(`${kind}1`)) / 19);
	console.log(`[${name}] per CPI: 0 heap bytes, ${perCall("signed")} CU signed, ${perCall("unsigned")} CU unsigned, ${perCall("builders")} CU with a 512-byte buffer`);
}

{
	const name = "rent";
	const base = (await run(OPS.seeds, 1)).value;
	for (const count of [1, 2, 100, 1000]) {
		const outcome = await run(OPS.rent, count);
		check(`[${name}] ${count} rent reads leave the heap position at ${base} (${outcome.ok ? `${outcome.units} CU` : outcome.error})`,
			outcome.ok && outcome.value === base);
	}
}

{
	const name = "reads";
	const base = (await run(OPS.seeds, 1)).value;
	const now = { slot: 123456789n, epochStartTimestamp: -5n, epoch: 7n, leaderScheduleEpoch: 8n, unixTimestamp: 1700000000n };
	svm.setClock(new Clock(now.slot, now.epochStartTimestamp, now.epoch, now.leaderScheduleEpoch, now.unixTimestamp));
	const wanted = (now.slot + now.epoch + now.leaderScheduleEpoch + now.unixTimestamp + now.epochStartTimestamp) & MASK;
	const owner = Buffer.from(getAddressEncoder().encode(program));
	const event = Buffer.concat([
		createHash("sha256").update("event:Probed").digest().subarray(0, 8),
		Buffer.from([7, 0, 0, 0, 0, 0, 0, 0]), owner, Buffer.from([1]),
	]);
	const sizes = [];
	for (const [kind, op] of [["clock", OPS.clock], ["returnData", OPS.returnData], ["logKey", OPS.logKey], ["event", OPS.event]]) {
		const positions = new Map();
		const units = new Map();
		for (const count of [1, 2, 8, 20, 40]) {
			const outcome = await run(op, count);
			positions.set(count, outcome.value);
			units.set(count, outcome.units);
			check(`[${name}] ${count} ${kind} reads leave the heap position at ${base} (${outcome.ok ? `${outcome.units} CU, position ${outcome.value}` : outcome.error})`,
				outcome.ok && outcome.value === base);
			if (kind === "clock" && outcome.ok) {
				check(`[${name}] ${count} clock reads sum every field the runtime holds`, outcome.first === ((wanted * BigInt(count)) & MASK));
			}
			if (kind === "logKey" && outcome.ok) {
				check(`[${name}] ${count} logPubkey calls log the program's base58 ${count} times`,
					outcome.logs.filter((line) => line === `Program log: ${program}`).length === count);
			}
			if (kind === "event" && outcome.ok) {
				check(`[${name}] ${count} events log Anchor's discriminator and the Borsh fields, ${count} times`,
					outcome.logs.filter((line) => line === `Program data: ${event.toString("base64")}`).length === count);
			}
		}
		sizes.push(`${kind} ${Number(positions.get(20) - positions.get(1)) / 19} B ${Math.round((units.get(20) - units.get(1)) / 19)} CU`);
	}
	const full = await run(OPS.fullReturn, 0);
	check(`[${name}] 1,024 bytes of return data come back whole, with the program that set them, and leave the heap position at ${base} (${full.ok ? `${full.units} CU` : full.error})`,
		full.ok && full.value === base);
	console.log(`[${name}] per call: ${sizes.join(", ")}`);
}

for (const [name, op] of Object.entries(OPS).filter(([name]) => name === "cells")) {
	check(`[${name}] a single round runs`, (await run(op, 1)).ok);
	const first = await firstFailure(op);
	check(`[${name}] some count exhausts the heap`, first !== null);
	if (first === null) continue;
	check(`[${name}] ${first - 1} rounds still run`, (await run(op, first - 1)).ok);
	const failed = namedFailure(`[${name}] ${first} rounds`, await run(op, first));
	if (failed !== null) {
		check(`[${name}] the request that failed did not fit (${failed.asked} bytes at ${failed.position})`,
			failed.asked % 8n === 0n && failed.position + failed.asked > BigInt(HEAP) && failed.position <= BigInt(HEAP));
	}
}

for (const [name, expected] of Object.entries(SUMS)) {
	const op = OPS[name];
	for (const count of [1, 3, 4, 5, 9, 17, 100, 250]) {
		const outcome = await run(op, count);
		check(`[${name}] ${count} elements grow and read back (${outcome.ok ? `${outcome.units} CU` : outcome.logs.find((line) => /Access violation|Overlapping copy|heap is exhausted/.test(line)) ?? outcome.error})`,
			outcome.ok && outcome.value === expected(BigInt(count)));
	}
	const first = await firstFailure(op);
	check(`[${name}] some count outgrows the heap`, first !== null);
	if (first === null) continue;
	const last = await run(op, first - 1);
	check(`[${name}] ${first - 1} elements still run and read back`, last.ok && last.value === expected(BigInt(first - 1)));
	const failed = namedFailure(`[${name}] ${first} elements`, await run(op, first));
	if (failed !== null) {
		check(`[${name}] the request that failed did not fit (${failed.asked} bytes at ${failed.position})`,
			failed.asked % 8n === 0n && failed.position + failed.asked > BigInt(HEAP) && failed.position <= BigInt(HEAP));
	}
}

{
	const name = "request";
	const first = await firstFailure(OPS.request);
	check(`[${name}] some size exhausts the heap`, first !== null);
	if (first !== null) {
		check(`[${name}] ${first - 1} bytes still run`, (await run(OPS.request, first - 1)).ok);
		const failed = namedFailure(`[${name}] ${first} bytes`, await run(OPS.request, first));
		if (failed !== null) {
			check(`[${name}] the last size that fits fills the heap to its end`, failed.position + BigInt(first - 1) === BigInt(HEAP));
			check(`[${name}] the log reports the request rounded to 8 (${failed.asked})`, failed.asked === BigInt(Math.ceil(first / 8) * 8));
		}
	}
}

for (const count of [1, 8, 4096]) {
	const label = `[wrap] a request for 2^64 - ${count} bytes`;
	const failed = namedFailure(label, await run(OPS.wrap, count));
	if (failed !== null) {
		check(`${label}: the log reports the size asked`, failed.asked === 2n ** 64n - BigInt(count));
	}
}

console.log(failures === 0 ? "heap exhaustion: every check passed" : `heap exhaustion: ${failures} check(s) FAILED`);
process.exit(failures === 0 ? 0 : 1);
