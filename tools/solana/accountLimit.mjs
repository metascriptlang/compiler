import {
	AccountRole,
	appendTransactionMessageInstruction,
	createKeyPairSignerFromPrivateKeyBytes,
	createTransactionMessage,
	getAddressDecoder,
	lamports,
	pipe,
	setTransactionMessageFeePayerSigner,
	setTransactionMessageLifetimeUsingBlockhash,
	signTransactionMessageWithSigners,
} from "@solana/kit";
import { LiteSVM } from "litesvm";

const [limitedPath, defaultPath] = process.argv.slice(2);
if (!limitedPath || !defaultPath) {
	console.error("usage: node accountLimit.mjs <limit2.so> <default.so>   (msc build tools/solana/accountLimitProbe.ms --os=solana --release [--passC=-DMS_SOL_MAX_ACCOUNTS=2] --output=…)");
	process.exit(2);
}

const svm = new LiteSVM();
const limited = (await createKeyPairSignerFromPrivateKeyBytes(new Uint8Array(32).fill(9))).address;
const unlimited = (await createKeyPairSignerFromPrivateKeyBytes(new Uint8Array(32).fill(8))).address;
svm.addProgramFromFile(limited, limitedPath);
svm.addProgramFromFile(unlimited, defaultPath);
const payer = await createKeyPairSignerFromPrivateKeyBytes(new Uint8Array(32).fill(1));
svm.airdrop(payer.address, lamports(10_000_000_000n));

const keyOf = (index) => {
	const bytes = new Uint8Array(32).fill(3);
	bytes[0] = 10 + index;
	return getAddressDecoder().decode(bytes);
};

let failures = 0;
function check(what, condition) {
	console.log(`${what}: ${condition ? "ok" : "FAILED"}`);
	if (!condition) failures++;
}

async function run(program, order) {
	const accounts = order.map((index) => ({ address: keyOf(index), role: AccountRole.READONLY }));
	const message = pipe(
		createTransactionMessage({ version: 0 }),
		(m) => setTransactionMessageFeePayerSigner(payer, m),
		(m) => setTransactionMessageLifetimeUsingBlockhash({ blockhash: svm.latestBlockhash(), lastValidBlockHeight: 1000n }, m),
		(m) => appendTransactionMessageInstruction({ programAddress: program, accounts, data: new Uint8Array([42]) }, m),
	);
	const result = svm.sendTransaction(await signTransactionMessageWithSigners(message));
	svm.expireBlockhash();
	const failed = result.constructor.name === "FailedTransactionMetadata";
	const meta = failed ? result.meta() : result;
	const logged = meta.logs().filter((l) => l.startsWith("Program log: ")).map((l) => BigInt(l.split(", ").pop()));
	return { ok: !failed, logged, logs: meta.logs() };
}

for (const [what, program, order, kept] of [
	["limit 2, five accounts", limited, [0, 1, 2, 3, 4], 2],
	["limit 2, repeats past the limit", limited, [0, 1, 0, 2, 1], 2],
	["limit 2, one account", limited, [0], 1],
	["limit 255, five accounts", unlimited, [0, 1, 2, 3, 4], 5],
]) {
	const outcome = await run(program, order);
	const want = [kept, 10 + order[kept - 1], 0, 1, 42].map(BigInt);
	check(`${what}: runs`, outcome.ok && !outcome.logs.some((l) => /Access violation/.test(l)));
	check(`${what}: sees ${kept} accounts, the last kept one, none past it, and the instruction data`,
		outcome.logged.join() === want.join());
}

if (failures > 0) {
	console.log(`${failures} FAILED`);
	process.exit(1);
}
console.log("all ok");
