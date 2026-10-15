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
	console.error("usage: node createAccountPrefund.mjs <createAccountPrefundProbe.so>   (msc build tools/solana/createAccountPrefundProbe.ms --os=solana --release --output=createAccountPrefundProbe.so)");
	process.exit(2);
}

const SYSTEM = address("11111111111111111111111111111111");
const svm = new LiteSVM();
const program = (await createKeyPairSignerFromPrivateKeyBytes(new Uint8Array(32).fill(9))).address;
svm.addProgramFromFile(program, programPath);
const payer = await createKeyPairSignerFromPrivateKeyBytes(new Uint8Array(32).fill(1));
svm.airdrop(payer.address, lamports(10_000_000_000n));
const rent = svm.minimumBalanceForRentExemption(16n);

let failures = 0;
function check(what, condition) {
	console.log(`${what}: ${condition ? "ok" : "FAILED"}`);
	if (!condition) failures++;
}

let seed = 40;
async function create(prefund) {
	const target = await createKeyPairSignerFromPrivateKeyBytes(new Uint8Array(32).fill(seed++));
	if (prefund > 0n) {
		svm.setAccount({ address: target.address, lamports: lamports(prefund), data: new Uint8Array(0), executable: false, programAddress: SYSTEM, space: 0n });
	}
	const message = pipe(
		createTransactionMessage({ version: 0 }),
		(m) => setTransactionMessageFeePayerSigner(payer, m),
		(m) => setTransactionMessageLifetimeUsingBlockhash({ blockhash: svm.latestBlockhash(), lastValidBlockHeight: 1000n }, m),
		(m) => appendTransactionMessageInstruction({
			programAddress: program,
			accounts: [
				{ address: payer.address, role: AccountRole.WRITABLE_SIGNER, signer: payer },
				{ address: target.address, role: AccountRole.WRITABLE_SIGNER, signer: target },
				{ address: SYSTEM, role: AccountRole.READONLY },
			],
			data: new Uint8Array([0]),
		}, m),
	);
	const result = svm.sendTransaction(await signTransactionMessageWithSigners(message));
	svm.expireBlockhash();
	const failed = result.constructor.name === "FailedTransactionMetadata";
	const made = svm.getAccount(target.address);
	return {
		ok: !failed,
		error: failed ? result.err().toString() : "",
		lamports: made.exists ? BigInt(made.lamports) : 0n,
		length: made.exists ? made.data.length : -1,
		owned: made.exists && made.programAddress === program,
	};
}

for (const [what, prefund, expected] of [
	["an empty address", 0n, rent],
	["an address that received one lamport first", 1n, rent],
	["an address that received half the rent first", rent / 2n, rent],
	["an address that received more than the rent first", rent * 3n, rent * 3n],
]) {
	const outcome = await create(prefund);
	check(`[${what}] createAccount succeeds`, outcome.ok);
	check(`[${what}] the account is 16 bytes, owned by the program and holds ${expected} lamports`, outcome.length === 16 && outcome.owned && outcome.lamports === expected);
}

if (failures > 0) {
	console.log(`${failures} FAILED`);
	process.exit(1);
}
console.log("all ok");
