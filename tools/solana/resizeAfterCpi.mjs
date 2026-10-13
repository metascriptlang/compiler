import { readFileSync } from "node:fs";
import {
	AccountRole,
	address,
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
	console.error("usage: node resizeAfterCpi.mjs <resizeProbe.so>   (msc build tools/solana/resizeProbe.ms --os=solana --output=resizeProbe.so)");
	process.exit(2);
}

const SYSTEM = address("11111111111111111111111111111111");
const LOGGED = /^Program log: 0x[0-9a-f]+, 0x[0-9a-f]+, 0x[0-9a-f]+, 0x[0-9a-f]+, 0x([0-9a-f]+)$/;
const svm = new LiteSVM();
const program = (await createKeyPairSignerFromPrivateKeyBytes(new Uint8Array(32).fill(9))).address;
svm.addProgramFromFile(program, programPath);
const payer = await createKeyPairSignerFromPrivateKeyBytes(new Uint8Array(32).fill(1));
svm.airdrop(payer.address, lamports(10_000_000_000n));
const neighbour = (await createKeyPairSignerFromPrivateKeyBytes(new Uint8Array(32).fill(7))).address;
svm.setAccount({ address: neighbour, lamports: lamports(5_000_000n), data: new Uint8Array(64).fill(0x5a), executable: false, programAddress: program, space: 64n });

let failures = 0;
function check(what, condition) {
	console.log(`${what}: ${condition ? "ok" : "FAILED"}`);
	if (!condition) failures++;
}

let seed = 20;
async function growAfterCreate(space, target, order) {
	const fresh = await createKeyPairSignerFromPrivateKeyBytes(new Uint8Array(32).fill(seed++));
	const roles = {
		payer: { address: payer.address, role: AccountRole.WRITABLE_SIGNER, signer: payer },
		fresh: { address: fresh.address, role: AccountRole.WRITABLE_SIGNER, signer: fresh },
		neighbour: { address: neighbour, role: AccountRole.READONLY },
		system: { address: SYSTEM, role: AccountRole.READONLY },
	};
	const data = new Uint8Array(6);
	const view = new DataView(data.buffer);
	view.setUint16(0, space, true);
	view.setUint16(2, target, true);
	data[4] = order.indexOf("fresh");
	data[5] = order.indexOf("neighbour");
	const message = pipe(
		createTransactionMessage({ version: 0 }),
		(m) => setTransactionMessageFeePayerSigner(payer, m),
		(m) => setTransactionMessageLifetimeUsingBlockhash({ blockhash: svm.latestBlockhash(), lastValidBlockHeight: 1000n }, m),
		(m) => appendTransactionMessageInstruction({ programAddress: program, accounts: order.map((name) => roles[name]), data }, m),
	);
	const result = svm.sendTransaction(await signTransactionMessageWithSigners(message));
	svm.expireBlockhash();
	const failed = result.constructor.name === "FailedTransactionMetadata";
	const logs = (failed ? result.meta() : result).logs();
	const values = logs.map((line) => LOGGED.exec(line)).filter((entry) => entry !== null).map((entry) => BigInt(`0x${entry[1]}`));
	return { ok: !failed, error: failed ? result.err().toString() : "", values, logs };
}

const ORDERS = {
	"a record follows": ["payer", "fresh", "neighbour", "system"],
	"a duplicate, then a record follow": ["payer", "fresh", "payer", "neighbour", "system"],
	"the instruction data follows": ["payer", "neighbour", "system", "fresh"],
};
const CASES = [
	{ space: 48, target: 10240, accepted: true },
	{ space: 48, target: 10248, accepted: false },
	{ space: 48, target: 10288, accepted: false },
	{ space: 10240, target: 20480, accepted: false },
];
for (const [layout, order] of Object.entries(ORDERS)) {
	for (const { space, target, accepted } of CASES) {
		const outcome = await growAfterCreate(space, target, order);
		if (process.env.RESIZE_LOGS) console.log(outcome.ok, outcome.error, outcome.values, outcome.logs);
		const [keyBefore, lamportsBefore, grown, keyAfter, lamportsAfter] = outcome.values;
		const label = `${layout}, created with ${space} bytes, grown to ${target}`;
		check(`${label}: ${accepted ? "accepted" : "refused"}`, grown === (accepted ? 1n : 0n) && outcome.ok);
		check(`${label}: the other account's key and lamports are intact`,
			keyBefore !== undefined && keyAfter === keyBefore && lamportsBefore === 5_000_000n && lamportsAfter === lamportsBefore);
	}
}
if (failures > 0) {
	console.error(`${failures} check(s) failed`);
	process.exit(1);
}
console.log("resize after a CPI: every check passed");
