import { createHash } from "node:crypto";
import {
	AccountRole,
	address,
	appendTransactionMessageInstruction,
	createKeyPairSignerFromPrivateKeyBytes,
	createTransactionMessage,
	getAddressEncoder,
	getProgramDerivedAddress,
	lamports,
	pipe,
	setTransactionMessageFeePayerSigner,
	setTransactionMessageLifetimeUsingBlockhash,
	signTransactionMessageWithSigners,
} from "@solana/kit";
import { LiteSVM } from "litesvm";

const [programPath, controlPath] = process.argv.slice(2);
if (!programPath) {
	console.error("usage: node checkCost.mjs <checkProbe.so> [<control checkProbe.so>]   (msc build tools/solana/checkProbe.ms --os=solana --output=checkProbe.so)");
	process.exit(2);
}

const SYSTEM = address("11111111111111111111111111111111");
const DELEGATION = address("DELeGGvXpWV2fqJUhqcF5ZSYMS4JTLjteaAMARRSaeSh");
const FEW = 8;
const encoder = getAddressEncoder();

const OPS = [
	["idle", 0],
	["owned<Pet>", 1],
	["mutable<Pet>", 2],
	["delegated<Pet>", 3],
	["accounts<Everything>", 4],
	["args<Parameters>", 5],
	["createPda<Pet>", 6],
	["create<Pet>", 7],
	["pda (Mutable)", 8],
	["pdaWithBump (Mutable)", 9],
	["pda (Delegated)", 10],
	["pdaWithBump (Delegated)", 11],
	["realloc<Pet>", 12],
	["close<Pet>", 13],
	["instruction<Dispatch> (last)", 14],
];

// Total compute units of each op with the std of commit 99d28088c, before the shared cores (compiler built from that tree).
const HEAD = {
	"idle": 235,
	"owned<Pet>": 802,
	"mutable<Pet>": 805,
	"delegated<Pet>": 798,
	"accounts<Everything>": 2698,
	"args<Parameters>": 564,
	"createPda<Pet>": 4272,
	"create<Pet>": 2169,
	"pda (Mutable)": 4443,
	"pdaWithBump (Mutable)": 3011,
	"pda (Delegated)": 2930,
	"pdaWithBump (Delegated)": 2997,
	"realloc<Pet>": 1110,
	"close<Pet>": 1020,
	"instruction<Dispatch> (last)": 566,
};

function u64(value) {
	const bytes = new Uint8Array(8);
	new DataView(bytes.buffer).setBigUint64(0, BigInt(value), true);
	return bytes;
}

function concat(...parts) {
	const out = new Uint8Array(parts.reduce((total, part) => total + part.length, 0));
	let offset = 0;
	for (const part of parts) {
		out.set(part, offset);
		offset += part.length;
	}
	return out;
}

function discriminator(preimage) {
	return new Uint8Array(createHash("sha256").update(preimage).digest().subarray(0, 8));
}

const PET_SIZE = 48;
const petData = (length = 8 + PET_SIZE, tag = discriminator("account:Pet")) => {
	const data = new Uint8Array(length);
	data.set(tag.subarray(0, Math.min(8, length)));
	return data;
};

const signerOf = (seed) => createKeyPairSignerFromPrivateKeyBytes(new Uint8Array(32).fill(seed));
const programSigner = await signerOf(7);
const payer = await signerOf(1);
const fresh = await signerOf(6);
const stranger = (await signerOf(9)).address;
const peekKey = (await signerOf(5)).address;
const derive = async (...seeds) => getProgramDerivedAddress({ programAddress: programSigner.address, seeds });
const [petKey, petBump] = await derive("pet", encoder.encode(payer.address));
const [targetKey] = await derive("new", encoder.encode(payer.address));
const [rolledKey, rolledBump] = await derive("rolled", encoder.encode(payer.address));

function parameters(op, bump, prefix = new Uint8Array(8)) {
	return concat(prefix, new Uint8Array([op]), u64(bump), new Uint8Array([1]), encoder.encode(stranger), new Uint8Array([bump]));
}

async function run(path, op, setup = {}) {
	const svm = new LiteSVM();
	svm.addProgramFromFile(programSigner.address, path);
	svm.airdrop(payer.address, lamports(10_000_000_000n));
	const put = (key, owner, data, rent = 10_000_000n) => svm.setAccount({
		address: key,
		data,
		executable: false,
		lamports: lamports(rent),
		programAddress: owner,
		space: BigInt(data.length),
	});
	const pet = setup.pet ?? {};
	put(pet.key ?? petKey, pet.owner ?? programSigner.address, pet.data ?? petData());
	put(setup.peekKey ?? peekKey, setup.peekOwner ?? programSigner.address, setup.peekData ?? petData());
	const rolledAt = setup.rolledAt ?? rolledKey;
	put(rolledAt, setup.rolledOwner ?? DELEGATION, petData());
	const prefix = setup.prefix ?? new Uint8Array(8);
	const data = setup.data ?? parameters(op, setup.bump ?? (op === 11 ? rolledBump : petBump), prefix);
	const accounts = [
		{ address: payer.address, role: AccountRole.WRITABLE_SIGNER, signer: payer },
		{ address: setup.target ?? targetKey, role: AccountRole.WRITABLE },
		{ address: pet.key ?? petKey, role: pet.readonly ? AccountRole.READONLY : AccountRole.WRITABLE },
		{ address: setup.peekKey ?? peekKey, role: AccountRole.READONLY },
		{ address: rolledAt, role: AccountRole.READONLY },
		{ address: fresh.address, role: AccountRole.WRITABLE_SIGNER, signer: fresh },
		{ address: SYSTEM, role: AccountRole.READONLY },
	];
	const message = pipe(
		createTransactionMessage({ version: 0 }),
		(m) => setTransactionMessageFeePayerSigner(payer, m),
		(m) => setTransactionMessageLifetimeUsingBlockhash({ blockhash: svm.latestBlockhash(), lastValidBlockHeight: 1000n }, m),
		(m) => appendTransactionMessageInstruction({ programAddress: programSigner.address, accounts, data }, m),
	);
	const result = svm.sendTransaction(await signTransactionMessageWithSigners(message));
	const failed = result.constructor.name === "FailedTransactionMetadata";
	const meta = failed ? result.meta() : result;
	return {
		ok: !failed,
		error: failed ? result.err().toString() : "",
		units: Number(meta.computeUnitsConsumed()),
		logs: meta.logs(),
		svm,
	};
}

let failures = 0;
function check(what, condition) {
	console.log(`${what}: ${condition ? "ok" : "FAILED"}`);
	if (!condition) failures++;
}

const last = discriminator("global:last");
const measured = new Map();
const controlled = new Map();
for (const [name, op] of OPS) {
	const prefix = op === 14 ? last : new Uint8Array(8);
	const outcome = await run(programPath, op, { prefix });
	check(`[${name}] the instruction runs${outcome.ok ? "" : ` (${outcome.error})`}`, outcome.ok);
	measured.set(name, outcome.units);
	if (controlled !== null && controlPath) {
		const before = await run(controlPath, op, { prefix });
		check(`[${name}] the control runs${before.ok ? "" : ` (${before.error})`}`, before.ok);
		controlled.set(name, before.units);
	}
}

const idle = measured.get("idle");
const idleBefore = controlPath ? controlled.get("idle") : HEAD.idle;
console.log(`\n${"op".padEnd(32)}${"total".padStart(8)}${"check".padStart(8)}${(controlPath ? "control" : "HEAD").padStart(9)}${"change".padStart(8)}`);
for (const [name] of OPS) {
	const cost = measured.get(name) - idle;
	const base = (controlPath ? controlled.get(name) - idleBefore : HEAD[name] - HEAD.idle);
	console.log(`${name.padEnd(32)}${String(measured.get(name)).padStart(8)}${String(cost).padStart(8)}${String(base).padStart(9)}${String(cost - base).padStart(8)}`);
}
if (!controlPath) {
	for (const [name] of OPS) {
		const cost = measured.get(name) - idle;
		const base = HEAD[name] - HEAD.idle;
		check(`[${name}] costs at most ${FEW} CU more than before (${cost} against ${base})`, cost <= base + FEW);
	}
}

const code = (outcome) => /InstructionErrorCustom \{ code: (\d+) \}/.exec(outcome.error)?.[1] ?? outcome.error;
const refuses = async (what, op, setup, expected) => {
	for (const path of controlPath ? [programPath, controlPath] : [programPath]) {
		const outcome = await run(path, op, setup);
		const label = path === programPath ? "" : " (control)";
		check(`${what}${label}: ${outcome.ok ? "accepted" : code(outcome)}, expected ${expected}`, !outcome.ok && code(outcome) === String(expected));
	}
};

await refuses("owned: the owner is another program", 1, { peekOwner: SYSTEM }, 3007);
await refuses("owned: no room for a discriminator", 1, { peekData: new Uint8Array(4) }, 3001);
await refuses("owned: another discriminator", 1, { peekData: petData(8 + PET_SIZE, discriminator("account:Other")) }, 3002);
await refuses("owned: a discriminator and too little data", 1, { peekData: petData(20) }, 3003);
await refuses("mutable: the account is read-only", 2, { pet: { readonly: true } }, 2000);
await refuses("delegated: owned by this program, not the delegation program", 3, { rolledOwner: programSigner.address }, 3007);
await refuses("accounts<T>: a Mutable field refuses a read-only account", 4, { pet: { readonly: true } }, 2000);
await refuses("args<T>: the data stops short of the arguments", 5, { data: parameters(5, 1).subarray(0, 20) }, 102);
await refuses("createPda: the target is not the PDA of the seeds", 6, { target: stranger }, 2006);
await refuses("pda: the account is not at the PDA of the seeds", 8, { pet: { key: stranger } }, 2006);
await refuses("pdaWithBump: another bump", 9, { bump: petBump - 1 }, 2006);
await refuses("pda (Delegated): the account is not at the PDA of the seeds", 10, { rolledAt: stranger }, 2006);
await refuses("instruction<T>: a discriminator no member has", 14, { prefix: discriminator("global:nobody") }, 101);

{
	const outcome = await run(programPath, 6, {});
	const stored = outcome.svm.getAccount(targetKey);
	check("createPda: the target holds the discriminator and the room of Pet",
		stored.exists && stored.data.length === 8 + PET_SIZE
			&& Buffer.from(stored.data.subarray(0, 8)).equals(Buffer.from(discriminator("account:Pet")))
			&& stored.programAddress === programSigner.address);
}
{
	const outcome = await run(programPath, 7, {});
	const stored = outcome.svm.getAccount(fresh.address);
	check("create: the new account holds the discriminator and the room of Pet",
		stored.exists && stored.data.length === 8 + PET_SIZE
			&& Buffer.from(stored.data.subarray(0, 8)).equals(Buffer.from(discriminator("account:Pet")))
			&& stored.programAddress === programSigner.address);
}
{
	const outcome = await run(programPath, 12, {});
	check("realloc: the account holds 200 bytes", outcome.svm.getAccount(petKey).data.length === 200);
}
{
	const outcome = await run(programPath, 13, {});
	const stored = outcome.svm.getAccount(petKey);
	check("close: the account is emptied", !stored.exists || stored.lamports === 0n);
}

if (failures > 0) {
	console.error(`checkCost: ${failures} check(s) failed`);
	process.exit(1);
}
console.log("checkCost: every op ran, every refusal kept its code");
