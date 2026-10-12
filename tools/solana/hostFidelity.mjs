import { createHash } from "node:crypto";
import {
	AccountRole,
	address,
	appendTransactionMessageInstruction,
	createKeyPairSignerFromPrivateKeyBytes,
	createTransactionMessage,
	getAddressDecoder,
	getAddressEncoder,
	getCompiledTransactionMessageDecoder,
	lamports,
	pipe,
	setTransactionMessageFeePayerSigner,
	setTransactionMessageLifetimeUsingBlockhash,
	signTransactionMessageWithSigners,
} from "@solana/kit";
import { LiteSVM } from "litesvm";
import { mainnetFeatures } from "./anchorSuites.mjs";
import { onCurve } from "./onCurve.mjs";

const [programPath] = process.argv.slice(2);
if (!programPath) {
	console.error("usage: node hostFidelity.mjs <hostFidelityProbe.so>   (msc build tools/solana/hostFidelityProbe.ms --os=solana --release --output=hostFidelityProbe.so)");
	process.exit(2);
}

const SYSTEM = address("11111111111111111111111111111111");
const OP = {
	nothing: 0, overlappingCopy: 1, returnData: 2, logBytes: 3, logAccountData: 4, createAddress: 5, findAddress: 6,
	validatePoint: 7, forward: 8, forwardAndCarryOn: 9, steps: 10,
};
const STEP = { add: 1, subtract: 2, write: 3, assign: 4, resize: 5, call: 6, callAndCarryOn: 7, log: 8, fail: 9, returns: 10 };
const NONE = 255;
const WRITABLE = 1;
const SIGNER = 2;
const LOGGED = /^Program log: 0x0, 0x0, 0x0, 0x0, 0x([0-9a-f]+)$/;
const encoder = getAddressEncoder();
const decoder = getAddressDecoder();
const keypair = (seed) => createKeyPairSignerFromPrivateKeyBytes(
	new Uint8Array(32).fill(seed & 255).map((byte, index) => seed > 255 && index === seed >> 8 ? byte ^ 0x80 : byte));
const program = (await keypair(9)).address;
const other = (await keypair(8)).address;
const names = new Map([[SYSTEM, "System"], [program, "the probe"], [other, "the callee"]]);
const OK = "ok";
const byProbe = (error) => `${error} by the probe`;
const bySystem = (error) => `${error} by System`;
const ABORTED = byProbe("ProgramFailedToComplete");
const ESCALATED = byProbe("PrivilegeEscalation");
const LOG_BUDGET = 10_000;

function u16(value) {
	return new Uint8Array([value & 255, value >> 8]);
}

function u32(value) {
	const bytes = new Uint8Array(4);
	new DataView(bytes.buffer).setUint32(0, value, true);
	return bytes;
}

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

const step = {
	add: (index, amount) => concat(new Uint8Array([STEP.add, index]), u64(amount)),
	subtract: (index, amount) => concat(new Uint8Array([STEP.subtract, index]), u64(amount)),
	write: (index, offset, value) => new Uint8Array([STEP.write, index, offset, value]),
	assign: (index, to) => new Uint8Array([STEP.assign, index, to]),
	resize: (index, length) => concat(new Uint8Array([STEP.resize, index]), u16(length)),
	call: (callee, metas, sent, { carryOn = false } = {}) => concat(
		new Uint8Array([carryOn ? STEP.callAndCarryOn : STEP.call, callee, metas.length]),
		...metas.map(([index, flags]) => new Uint8Array([index, flags])), new Uint8Array([sent.length]), sent),
	log: (value) => new Uint8Array([STEP.log, value]),
	fail: (code) => new Uint8Array([STEP.fail, code]),
	returns: (length) => new Uint8Array([STEP.returns, length]),
};
const steps = (...parts) => concat(new Uint8Array([OP.steps]), ...parts);

function derived(seed) {
	return createHash("sha256").update(seed).update(encoder.encode(program)).update("ProgramDerivedAddress").digest();
}

function seedWhere(wanted, from) {
	for (let counter = from; ; counter++) {
		const seed = concat(new TextEncoder().encode("seed"), u32(counter));
		if (onCurve(derived(seed)) === wanted) return seed;
	}
}

const ON_CURVE_SEED = seedWhere(true, 0);
const PDA_SEED = seedWhere(false, 0);
const OTHER_PDA_SEED = seedWhere(false, 1000);
const PDA = decoder.decode(derived(PDA_SEED));
const OTHER_PDA = decoder.decode(derived(OTHER_PDA_SEED));

let failures = 0;

async function scenario(label, features, body) {
	const svm = features === "mainnet"
		? new LiteSVM().withFeatureSet(mainnetFeatures()).withBuiltins().withSysvars().withDefaultPrograms()
		: new LiteSVM();
	svm.addProgramFromFile(program, programPath);
	svm.addProgramFromFile(other, programPath);
	const payer = await keypair(1);
	svm.airdrop(payer.address, lamports(10_000_000_000n));
	let nextSeed = 20;
	const signers = new Map([[payer.address, payer]]);

	async function fresh() {
		const made = await keypair(nextSeed++);
		signers.set(made.address, made);
		return made.address;
	}

	function put(account, { data = new Uint8Array(), owner = SYSTEM, balance = null } = {}) {
		svm.setAccount({
			address: account,
			data,
			executable: false,
			lamports: lamports(balance ?? svm.minimumBalanceForRentExemption(BigInt(data.length))),
			programAddress: owner,
			space: BigInt(data.length),
		});
		return account;
	}

	const meta = (account, writable, signer = false) => ({ address: account, writable, signer });

	async function send(step, data, metas, expected, because = "", { leading = 0 } = {}) {
		const accounts = metas.map((entry) => ({
			address: entry.address,
			role: entry.signer
				? (entry.writable ? AccountRole.WRITABLE_SIGNER : AccountRole.READONLY_SIGNER)
				: (entry.writable ? AccountRole.WRITABLE : AccountRole.READONLY),
			...(entry.signer ? { signer: signers.get(entry.address) } : {}),
		}));
		const message = pipe(
			createTransactionMessage({ version: 0 }),
			(m) => setTransactionMessageFeePayerSigner(payer, m),
			(m) => setTransactionMessageLifetimeUsingBlockhash(
				{ blockhash: svm.latestBlockhash(), lastValidBlockHeight: 1000n },
				m,
			),
			(m) => Array.from({ length: leading }).reduce((built) => appendTransactionMessageInstruction(
				{ programAddress: program, accounts: [], data: new Uint8Array([OP.nothing]) }, built), m),
			(m) => appendTransactionMessageInstruction({ programAddress: program, accounts, data }, m),
		);
		const signed = await signTransactionMessageWithSigners(message);
		const keys = getCompiledTransactionMessageDecoder().decode(signed.messageBytes).staticAccounts;
		const result = svm.sendTransaction(signed);
		svm.expireBlockhash();
		const failed = result.constructor.name === "FailedTransactionMetadata";
		const logs = (failed ? result.meta() : result).logs();
		const refusedBy = logs.filter((line) => / failed: /.test(line)).map((line) => line.split(" ")[1])[0] ?? "";
		const values = logs.map((line) => LOGGED.exec(line)).filter((entry) => entry !== null).map((entry) => BigInt(`0x${entry[1]}`));
		const raw = failed ? result.err().toString() : "";
		const error = failed
			? raw.replace(/^TransactionErrorInstructionError \{ index: \d+, error: /, "")
				.replace("InstructionErrorCustom { code: ", "custom ").replaceAll(" }", "")
				.replace(/^TransactionError(\w+) \{ account_index: \d+$/, "$1")
			: "";
		const reason = logs.filter((line) => / failed: /.test(line)).map((line) => line.split(" failed: ")[1])[0] ?? "";
		const answer = failed ? `${error} by ${refusedBy === "" ? "the transaction" : names.get(refusedBy)}` : "ok";
		const passed = answer === expected && reason.includes(because);
		const shown = `${answer}${reason === "" ? "" : ` (${reason})`}`;
		console.log(`[${features}] [${label}] ${step}: ${shown}${passed ? "" : `  <-- FAILED, expected ${expected} ${because}`}`);
		if (process.env.HOST_FIDELITY_LOGS) console.log(logs.join("\n"));
		if (!passed) failures++;
		const blamed = /account_index: (\d+)/.exec(raw);
		return {
			failed, logs, values, raw,
			blamed: blamed === null ? null : keys[Number(blamed[1])],
			returned: (failed ? result.meta() : result).returnData().data(),
		};
	}

	function check(what, condition) {
		console.log(`[${features}] [${label}] ${what}: ${condition ? "ok" : "FAILED"}`);
		if (!condition) failures++;
	}

	function forward(step, callee, metas, sent, expected, { drained = NONE, seeds = null, sink = null, because = "", carryOn = false } = {}) {
		const flags = new Uint8Array(4);
		metas.forEach((entry, index) => { flags[index] = (entry.cpiWritable ? WRITABLE : 0) | (entry.cpiSigner ? SIGNER : 0); });
		const seed = seeds === null ? new Uint8Array() : seeds.bytes;
		const data = concat(new Uint8Array([carryOn ? OP.forwardAndCarryOn : OP.forward, drained, metas.length]), flags,
			new Uint8Array([seeds === null ? 0 : seeds.signers ?? 1, seeds === null ? 0 : seeds.count, seed.length]), seed, sent);
		const passed = [meta(callee, false), ...metas.map((entry) => meta(entry.address, entry.writable, entry.signer))];
		if (sink !== null) passed.push(meta(sink, true));
		return send(step, data, passed, expected, because);
	}

	const held = (account, { writable = true, signer = false, cpiWritable = writable, cpiSigner = signer } = {}) =>
		({ address: account, writable, signer, cpiWritable, cpiSigner });

	await body({ svm, payer, fresh, put, meta, send, check, forward, held });
}

for (const features of ["all features", "mainnet"]) {
	await scenario("syscalls", features, async (t) => {
		const none = [];
		const status = (outcome) => outcome.values[0];
		await t.send("a copy onto the bytes next to its source", new Uint8Array([OP.overlappingCopy, 8]), none, OK);
		await t.send("a copy onto bytes 4 past its source",
			new Uint8Array([OP.overlappingCopy, 4]), none, ABORTED, "Overlapping copy");
		await t.send("a copy onto its own source", new Uint8Array([OP.overlappingCopy, 0]), none, ABORTED, "Overlapping copy");
		await t.send("return data of 1024 bytes", concat(new Uint8Array([OP.returnData]), u16(1024)), none, OK);
		await t.send("return data of 1025 bytes",
			concat(new Uint8Array([OP.returnData]), u16(1025)), none, ABORTED, "Return data too large (1025 > 1024)");

		const logged = async (what, bytes, expected, because = "") => {
			const outcome = await t.send(`a log line of ${what}`, new Uint8Array([OP.logBytes, ...bytes]), none, expected, because);
			return outcome.logs.filter((line) => line.startsWith("Program log: ") && !LOGGED.test(line));
		};
		t.check("the text is logged", (await logged("two-byte characters", [0x68, 0xc3, 0xa9], OK))[0] === "Program log: hé");
		t.check("an empty line is logged", (await logged("no bytes", [], OK))[0] === "Program log: ");
		t.check("the zero byte and what follows it are logged", (await logged("a zero byte inside", [0x61, 0, 0x62], OK))[0] === "Program log: a\u0000b");
		t.check("nothing is logged", (await logged("byte 0xff", [0x61, 0xff], ABORTED, "invalid utf-8 sequence")).length === 0);
		await logged("a two-byte character cut after its first byte", [0x61, 0xc3], ABORTED, "incomplete utf-8 byte sequence");
		await logged("a surrogate encoded in three bytes", [0xed, 0xa0, 0x80], ABORTED, "invalid utf-8 sequence");
		await logged("a two-byte encoding of a one-byte character", [0xc0, 0xaf], ABORTED, "invalid utf-8 sequence");
		await logged("a code point above U+10FFFF", [0xf4, 0x90, 0x80, 0x80], ABORTED, "invalid utf-8 sequence");
		await logged("the last code point, U+10FFFF", [0xf4, 0x8f, 0xbf, 0xbf], OK);

		const derive = (op, count, length) => new Uint8Array([op, count, length]);
		const TOO_LONG = "Length of the seed is too long for address generation";
		for (const [name, op] of [["create_program_address", OP.createAddress], ["try_find_program_address", OP.findAddress]]) {
			t.check("status 0", status(await t.send(`${name} of no seeds`, derive(op, 0, 0), none, OK)) === 0n);
			await t.send(`${name} of 17 seeds`, derive(op, 17, 1), none, ABORTED, TOO_LONG);
			await t.send(`${name} of a seed of 33 bytes`, derive(op, 1, 33), none, ABORTED, TOO_LONG);
		}
		t.check("status 1, the address is on the curve",
			status(await t.send("create_program_address of 16 seeds", derive(OP.createAddress, 16, 1), none, OK)) === 1n);
		t.check("status 0",
			status(await t.send("try_find_program_address of a seed of 32 bytes", derive(OP.findAddress, 1, 32), none, OK)) === 0n);

		const validate = (curve) => t.send(`curve_validate_point on curve ${curve}`, new Uint8Array([OP.validatePoint, curve]), none,
			curve < 2 ? OK : ABORTED, curve < 2 ? "" : "InvalidAttribute");
		t.check("status 0, the point is on the edwards curve", status(await validate(0)) === 0n);
		t.check("status 1, the same bytes are no ristretto point", status(await validate(1)) === 1n);
		for (const curve of [2, 3, 200]) await validate(curve);
	});

	await scenario("log budget", features, async (t) => {
		const text = t.put(await t.fresh(), { data: new Uint8Array(30000).fill(0x61), owner: program });
		const invokeLine = `Program ${program} invoke [1]`.length;
		for (const [length, count, truncated] of [
			[9000, 1, false], [9800, 1, true], [9900, 1, true], [10000, 1, true], [20000, 1, true], [1000, 12, true], [100, 120, true],
		]) {
			const outcome = await t.send(`${count} log line(s) of ${length} bytes`,
				concat(new Uint8Array([OP.logAccountData]), u16(length), u16(count)), [t.meta(text, false)], OK);
			const fit = Math.min(count, Math.ceil((LOG_BUDGET - invokeLine) / (13 + length)) - 1);
			t.check(`${fit} line(s) are kept, the ones that keep the total under ${LOG_BUDGET} bytes`,
				outcome.logs.filter((line) => line.startsWith("Program log: aa")).length === fit);
			t.check(truncated ? "one line says the log is truncated" : "nothing says the log is truncated",
				outcome.logs.filter((line) => line === "Log truncated").length === (truncated ? 1 : 0));
		}
	});

	await scenario("CPI privileges", features, async (t) => {
		const wallet = t.put(await t.fresh(), { balance: 1_000_000_000n });
		const stranger = t.put(await t.fresh(), { balance: 1_000_000_000n });
		t.put(PDA, { balance: 1_000_000_000n });
		const NO_ADDRESS = "Could not create program address with signer seeds: Provided seeds do not result in a valid address";
		for (const [who, callee, sent] of [
			["the callee", other, new Uint8Array([OP.nothing])],
			["System", SYSTEM, concat(u32(2), u64(1))],
		]) {
			const signed = [t.held(wallet, { signer: true }), t.held(stranger)];
			const byPda = [t.held(PDA, { cpiSigner: true }), t.held(stranger)];
			const readOnly = t.held(stranger, { writable: false, cpiWritable: true });
			const seeds = (count, bytes, signers = 1) => ({ seeds: { signers, count, bytes } });
			const to = async (step, metas, expected, options = {}) => {
				await t.forward(`${who}: ${step}`, callee, metas, sent, expected, options);
				await t.forward(`${who}: ${step}, by a program that carries on after the call`, callee, metas, sent, expected,
					{ ...options, carryOn: true });
			};
			await to("metas as the caller holds them", signed, OK);
			await to("a signer meta the caller does not hold, no seeds",
				[t.held(stranger, { cpiSigner: true }), t.held(wallet, { signer: true })], ESCALATED);
			await to("seeds that derive the account marked signer", byPda, OK, seeds(1, PDA_SEED));
			await to("seeds that derive another address", byPda, ESCALATED, seeds(1, OTHER_PDA_SEED));
			await to("a writable meta on an account passed read-only", [t.held(wallet, { signer: true }), readOnly], ESCALATED);
			await to("signer seeds that hash onto the curve",
				signed, ABORTED, { ...seeds(1, ON_CURVE_SEED), because: NO_ADDRESS });
			await to("signer seeds that hash onto the curve and a writable meta on an account passed read-only",
				[t.held(wallet, { signer: true }), readOnly], ABORTED, { ...seeds(1, ON_CURVE_SEED), because: NO_ADDRESS });
			await to("a signer of no seeds", signed, OK, seeds(0, new Uint8Array()));
			await to("a signer of 17 seeds", signed, byProbe("MaxSeedLengthExceeded"), seeds(17, new Uint8Array(1)));
			await to("a signer of 17 seeds of 33 bytes", signed, byProbe("MaxSeedLengthExceeded"), seeds(17, new Uint8Array(33)));
			await to("a signer seed of 33 bytes", signed, ABORTED,
				{ ...seeds(1, new Uint8Array(33)), because: "Length of the seed is too long for address generation" });
			await to("16 signers", signed, OK, seeds(1, PDA_SEED, 16));
			await to("17 signers", signed, ABORTED, { ...seeds(1, PDA_SEED, 17), because: "Too many signers" });
			await to("17 signers of 17 seeds",
				signed, ABORTED, { ...seeds(17, new Uint8Array(1), 17), because: "Too many signers" });
		}
		const spent = () => t.held(t.put(OTHER_PDA, { owner: program, balance: 1_000_000_000n }));
		const nothing = new Uint8Array([OP.nothing]);
		await t.forward("a call that receives both accounts the caller moved lamports between",
			other, [spent(), t.held(stranger)], nothing, OK,
			{ drained: 1 });
		await t.forward("a call that does not receive the account the caller moved lamports to", other, [spent()], nothing,
			byProbe("UnbalancedInstruction"), { drained: 1, sink: stranger });
	});

	await scenario("System", features, async (t) => {
		const rent = (space) => t.svm.minimumBalanceForRentExemption(BigInt(space));
		const SOL = 1_000_000_000n;
		const TOO_LARGE = 10 * 1024 * 1024 + 1;
		const IN_USE = bySystem("custom 0");
		const TOO_FEW_LAMPORTS = bySystem("custom 1");
		const INVALID_LENGTH = bySystem("custom 3");
		const UNSIGNED = bySystem("MissingRequiredSignature");
		const SHORT = bySystem("InvalidInstructionData");
		const MISSING = bySystem("MissingAccount");
		const HAS_DATA = bySystem("InvalidArgument");
		const NOT_ITS_LAMPORTS = bySystem("ExternalAccountLamportSpend");
		const READ_ONLY_LAMPORTS = bySystem("ReadonlyLamportChange");
		const READ_ONLY_DATA = bySystem("ReadonlyDataModified");
		const NOT_ITS_OWNER = bySystem("ModifiedProgramId");
		const GREW_TOO_FAR = byProbe("InvalidRealloc");
		const create = (amount, space, owner = program, tag = 0) => concat(u32(tag), u64(amount), u64(space), encoder.encode(owner));
		const prefund = (amount, space, owner = program) => create(amount, space, owner, 13);
		const assign = (owner) => concat(u32(1), encoder.encode(owner));
		const transfer = (amount) => concat(u32(2), u64(amount));
		const allocate = (space) => concat(u32(8), u64(space));
		const wallet = async () => t.put(await t.fresh(), { balance: SOL });
		const laden = async (fill = 0) => t.put(await t.fresh(), { data: new Uint8Array(8).fill(fill), balance: SOL });
		const blank = () => t.fresh();
		const programOwned = (seed, data = new Uint8Array()) => t.put(decoder.decode(derived(seed)), { data, owner: program, balance: SOL });
		const signer = (account, extra = {}) => t.held(account, { signer: true, ...extra });
		const pda = (extra = {}) => t.held(PDA, { cpiSigner: true, ...extra });
		const bySeed = (bytes) => ({ seeds: { count: 1, bytes } });
		const stored = (account) => t.svm.getAccount(account);
		const system = (step, metas, sent, expected, options = {}) => t.forward(step, SYSTEM, metas, sent, expected, options);
		const pays = await wallet();
		const takes = await wallet();
		programOwned(OTHER_PDA_SEED, new Uint8Array(8));
		programOwned(PDA_SEED);

		await system("Transfer", [signer(pays), t.held(takes)], transfer(5), OK);
		t.check("5 lamports moved", stored(pays).lamports === SOL - 5n && stored(takes).lamports === SOL + 5n);
		await system("Transfer with a byte after its data",
			[signer(pays), t.held(takes)], concat(transfer(5), new Uint8Array(1)), OK);
		await system("Transfer to itself", [signer(pays), signer(pays)], transfer(5), OK);
		await system("Transfer to itself of more than it holds",
			[signer(pays), signer(pays)], transfer(2n * SOL), TOO_FEW_LAMPORTS);
		await system("Transfer with 8 bytes of data", [signer(pays), t.held(takes)], transfer(5).subarray(0, 8), SHORT);
		await system("Transfer with 8 bytes of data and one account", [signer(pays)], transfer(5).subarray(0, 8), SHORT);
		await system("Transfer with one account", [signer(pays)], transfer(5), MISSING);
		await system("Transfer from an account the instruction does not mark as a signer",
			[signer(pays, { cpiSigner: false }), t.held(takes)], transfer(5), UNSIGNED);
		await system("Transfer from an unsigned account that carries data",
			[signer(await laden(), { cpiSigner: false }), t.held(takes)], transfer(5), UNSIGNED);
		await system("Transfer from an account that carries data", [signer(await laden()), t.held(takes)], transfer(5), HAS_DATA);
		await system("Transfer of nothing from an account that carries data",
			[signer(await laden()), t.held(takes)], transfer(0), HAS_DATA);
		await system("Transfer from an account another program owns that carries data",
			[t.held(OTHER_PDA, { cpiSigner: true }), t.held(takes)], transfer(5), HAS_DATA, bySeed(OTHER_PDA_SEED));
		await system("Transfer of more than the account holds",
			[signer(pays), t.held(takes)], transfer(2n * SOL), TOO_FEW_LAMPORTS);
		await system("Transfer of more than it holds from an account another program owns",
			[pda(), t.held(takes)], transfer(2n * SOL), TOO_FEW_LAMPORTS, bySeed(PDA_SEED));
		await system("Transfer of more than it holds from an account not marked writable",
			[signer(pays, { cpiWritable: false }), t.held(takes)], transfer(2n * SOL), TOO_FEW_LAMPORTS);
		await system("Transfer from an account another program owns",
			[pda(), t.held(takes)], transfer(5), NOT_ITS_LAMPORTS, bySeed(PDA_SEED));
		await system("Transfer from an account another program owns, not marked writable",
			[pda({ cpiWritable: false }), t.held(takes)], transfer(5), NOT_ITS_LAMPORTS, bySeed(PDA_SEED));
		await system("Transfer of nothing from an account another program owns",
			[pda(), t.held(takes)], transfer(0), OK, bySeed(PDA_SEED));
		await system("Transfer from an account not marked writable",
			[signer(pays, { cpiWritable: false }), t.held(takes)], transfer(5), READ_ONLY_LAMPORTS);
		await system("Transfer of nothing from an account not marked writable",
			[signer(pays, { cpiWritable: false }), t.held(takes)], transfer(0), READ_ONLY_LAMPORTS);
		await system("Transfer to an account not marked writable",
			[signer(pays), t.held(takes, { cpiWritable: false })], transfer(5), READ_ONLY_LAMPORTS);
		await system("Transfer of nothing to an account not marked writable",
			[signer(pays), t.held(takes, { cpiWritable: false })], transfer(0), READ_ONLY_LAMPORTS);
		const brimming = t.put(await t.fresh(), { balance: 0xffff_ffff_ffff_fff0n });
		await system("Transfer beyond a balance of 2^64 - 1",
			[signer(pays), t.held(brimming)], transfer(100), bySystem("ArithmeticOverflow"));
		await system("Transfer beyond a balance of 2^64 - 1 to an account not marked writable",
			[signer(pays), t.held(brimming, { cpiWritable: false })], transfer(100), bySystem("ArithmeticOverflow"));

		for (const prefunds of [false, true]) {
			const name = prefunds ? "CreateAccountAllowPrefund" : "CreateAccount";
			const build = prefunds ? prefund : create;
			const order = (payer, target) => prefunds ? [target, payer] : [payer, target];
			const creates = (step, payer, target, sent, expected, options = {}) => system(`${name} ${step}`, order(payer, target), sent, expected, options);
			const sized = build(rent(8), 8);
			const made = await blank();
			await system(name, order(signer(pays), signer(made)), sized, OK);
			t.check("the account has 8 zero bytes, the lamports and the owner",
				stored(made).programAddress === program && stored(made).data.length === 8 && stored(made).lamports === rent(8));
			await creates("of no lamports and no bytes", signer(pays), signer(await blank()), build(0, 0), OK);
			await creates("of 10240 bytes", signer(pays), signer(await blank()), build(rent(10240), 10240), OK);
			await creates("with 51 bytes of data", signer(pays), signer(await blank()), sized.subarray(0, 51), SHORT);
			await system(`${name} with one account`, [signer(await blank())], sized, MISSING);
			await system(`${name} with one account, at an address that holds data`, [signer(await laden())], sized, MISSING);
			await system(`${name} of no lamports with one account`,
				[signer(await blank())], build(0, 8), prefunds ? OK : MISSING);
			await system(`${name} of no lamports at an address that holds lamports, with one account`,
				[signer(await wallet())], build(0, 8), prefunds ? OK : MISSING);

			await creates("at an address that holds lamports",
				signer(pays), signer(await wallet()), sized, prefunds ? OK : IN_USE);
			await creates("at an unsigned address that holds lamports",
				signer(pays), signer(await wallet(), { cpiSigner: false }), sized, prefunds ? UNSIGNED : IN_USE);
			await creates("at an address the instruction does not mark as a signer",
				signer(pays), signer(await blank(), { cpiSigner: false }), sized, UNSIGNED);
			await creates("at an address that holds data", signer(pays), signer(await laden()), sized, IN_USE);
			await creates("at an unsigned address that holds data",
				signer(pays), signer(await laden(), { cpiSigner: false }), sized, prefunds ? UNSIGNED : IN_USE);
			programOwned(PDA_SEED);
			await creates("at an address another program owns", signer(pays), pda(), sized, IN_USE, bySeed(PDA_SEED));
			const drained = { ...bySeed(PDA_SEED), drained: prefunds ? 1 : 2, sink: pays };
			await creates("at an address another program owns, with no lamports", signer(pays), pda(), sized, IN_USE, drained);
			programOwned(PDA_SEED, new Uint8Array(8));
			await creates("at an address another program owns, with data and no lamports",
				signer(pays), pda(), sized, IN_USE, drained);
			programOwned(PDA_SEED);
			await creates("from a payer that carries data at an address that holds data",
				signer(await laden()), signer(await laden()), sized, IN_USE);
			await creates("of 10 MiB and a byte at an address that holds data",
				signer(pays), signer(await laden()), build(rent(8), TOO_LARGE), IN_USE);
			await creates("of 10 MiB and a byte", signer(pays), signer(await blank()), build(rent(8), TOO_LARGE), INVALID_LENGTH);
			await creates("of 10 MiB and a byte from a payer that carries data",
				signer(await laden()), signer(await blank()), build(rent(8), TOO_LARGE), INVALID_LENGTH);
			await creates("at an address not marked writable",
				signer(pays), signer(await blank(), { cpiWritable: false }), sized, READ_ONLY_DATA);
			await creates("of no bytes at an address not marked writable",
				signer(pays), signer(await blank(), { cpiWritable: false }), build(rent(0), 0), READ_ONLY_DATA);
			await creates("of no bytes for the System program at an address not marked writable",
				signer(pays), signer(await blank(), { cpiWritable: false }), build(rent(0), 0, SYSTEM), READ_ONLY_DATA);

			await creates("from a payer the instruction does not mark as a signer",
				signer(pays, { cpiSigner: false }), signer(await blank()), sized, UNSIGNED);
			await creates("from an unsigned payer that carries data",
				signer(await laden(), { cpiSigner: false }), signer(await blank()), sized, UNSIGNED);
			await creates("of no lamports from an unsigned payer",
				signer(pays, { cpiSigner: false }), signer(await blank()), build(0, 8), prefunds ? OK : UNSIGNED);
			await creates("from a payer that carries data", signer(await laden()), signer(await blank()), sized, HAS_DATA);
			await creates("of no lamports from a payer that carries data",
				signer(await laden()), signer(await blank()), build(0, 8), prefunds ? OK : HAS_DATA);
			await creates("for more lamports than the payer holds",
				signer(pays), signer(await blank()), build(2n * SOL, 8), TOO_FEW_LAMPORTS);
			await creates("of 10241 bytes for more lamports than the payer holds",
				signer(pays), signer(await blank()), build(2n * SOL, 10241), TOO_FEW_LAMPORTS);
			await creates("from a payer another program owns",
				pda(), signer(await blank()), sized, NOT_ITS_LAMPORTS, bySeed(PDA_SEED));
			await creates("from a payer not marked writable",
				signer(pays, { cpiWritable: false }), signer(await blank()), sized, READ_ONLY_LAMPORTS);
			await creates("of 10241 bytes", signer(pays), signer(await blank()), build(rent(10241), 10241), GREW_TOO_FAR);

			await system(`${name} with the payer as the new account`,
				[signer(pays), signer(pays)], sized, prefunds ? HAS_DATA : IN_USE);
			await system(`${name} with the payer as the new account, of no bytes`,
				[signer(pays), signer(pays)], build(5, 0), prefunds ? NOT_ITS_LAMPORTS : IN_USE);
			await system(`${name} with the payer as the new account, of no bytes, for the System program`,
				[signer(pays), signer(pays)], build(5, 0, SYSTEM), prefunds ? OK : IN_USE);
		}

		const BELOW_RENT = "InsufficientFundsForRent by the transaction";
		await system("CreateAccount for fewer lamports than 8 bytes need to be rent exempt",
			[signer(pays), signer(await blank())], create(rent(8) - 1n, 8), BELOW_RENT);
		await system("Transfer that leaves a new account below rent exemption",
			[signer(pays), t.held(await blank())], transfer(1), BELOW_RENT);

		const sized = await wallet();
		await system("Allocate", [signer(sized)], allocate(8), OK);
		t.check("the account has 8 bytes and stays the System program's", stored(sized).data.length === 8 && stored(sized).programAddress === SYSTEM);
		await system("Allocate of no bytes", [signer(await wallet())], allocate(0), OK);
		await system("Allocate of 10240 bytes", [signer(await wallet())], allocate(10240), OK);
		await system("Allocate on an account that holds no lamports", [signer(await blank())], allocate(8), OK);
		await system("Allocate with 8 bytes of data", [signer(await wallet())], allocate(8).subarray(0, 8), SHORT);
		await system("Allocate with no account", [], allocate(8), MISSING);
		await system("Allocate on an account the instruction does not mark as a signer",
			[signer(await wallet(), { cpiSigner: false })], allocate(8), UNSIGNED);
		await system("Allocate on an unsigned account that holds data",
			[signer(await laden(), { cpiSigner: false })], allocate(8), UNSIGNED);
		await system("Allocate on an account that holds data", [signer(sized)], allocate(16), IN_USE);
		await system("Allocate on an account another program owns", [pda()], allocate(8), IN_USE, bySeed(PDA_SEED));
		await system("Allocate of 10 MiB and a byte on an account that holds data",
			[signer(await laden())], allocate(TOO_LARGE), IN_USE);
		await system("Allocate of 10 MiB and a byte", [signer(await wallet())], allocate(TOO_LARGE), INVALID_LENGTH);
		await system("Allocate on an account not marked writable",
			[signer(await wallet(), { cpiWritable: false })], allocate(8), READ_ONLY_DATA);
		await system("Allocate of no bytes on an account not marked writable",
			[signer(await wallet(), { cpiWritable: false })], allocate(0), READ_ONLY_DATA);
		await system("Allocate of 10241 bytes", [signer(await wallet())], allocate(10241), GREW_TOO_FAR);

		const given = await wallet();
		await system("Assign", [signer(given)], assign(program), OK);
		t.check("the account is the program's", stored(given).programAddress === program);
		await system("Assign on an account that holds zero bytes", [signer(await laden())], assign(program), OK);
		await system("Assign to the owner the account has, without its signature",
			[signer(await wallet(), { cpiSigner: false })], assign(SYSTEM), OK);
		await system("Assign to the owner the account has, not marked writable",
			[signer(await wallet(), { cpiWritable: false })], assign(SYSTEM), OK);
		await system("Assign with 35 bytes of data", [signer(await wallet())], assign(program).subarray(0, 35), SHORT);
		await system("Assign with 35 bytes of data and no account", [], assign(program).subarray(0, 35), SHORT);
		await system("Assign with no account", [], assign(program), MISSING);
		await system("Assign on an account the instruction does not mark as a signer",
			[signer(await wallet(), { cpiSigner: false })], assign(program), UNSIGNED);
		await system("Assign on an unsigned account another program owns", [t.held(PDA)], assign(other), UNSIGNED);
		await system("Assign on an account another program owns", [pda()], assign(other), NOT_ITS_OWNER, bySeed(PDA_SEED));
		await system("Assign on an account that holds bytes that are not zero",
			[signer(await laden(7))], assign(program), NOT_ITS_OWNER);
		await system("Assign on an account not marked writable",
			[signer(await wallet(), { cpiWritable: false })], assign(program), NOT_ITS_OWNER);
	});
	await scenario("a failed call", features, async (t) => {
		const SOL = 1_000_000_000n;
		const pays = t.put(await t.fresh(), { balance: SOL });
		const takes = t.put(await t.fresh(), { balance: SOL });
		const passed = [t.meta(SYSTEM, false), t.meta(pays, true, true), t.meta(takes, true), t.meta(other, false)];
		const transfer = (amount) => concat(u32(2), u64(amount));
		const AFTER = 5;
		const cases = [
			["a System Transfer of more than the payer holds", step.call, 0, [[1, 3], [2, 1]], transfer(2n * SOL), bySystem("custom 1"), "custom program error: 0x1"],
			["a System Transfer the payer does not sign", step.call, 0, [[1, 1], [2, 1]], transfer(5), bySystem("MissingRequiredSignature"), "missing required signature"],
			["a callee that fails with custom error 7", step.call, 3, [], steps(step.fail(7)), "custom 7 by the callee", "custom program error: 0x7"],
			["a callee that fails with InvalidInstructionData", step.call, 3, [], new Uint8Array([200]), "InvalidInstructionData by the callee", "invalid instruction data"],
		];
		for (const [what, call, callee, metas, sent, expected, reason] of cases) {
			for (const carryOn of [false, true]) {
				const outcome = await t.send(`${what}, ${carryOn ? "by a program that carries on" : "by a program that returns the error"}`,
					steps(call(callee, metas, sent, { carryOn }), step.log(AFTER)), passed, expected, reason);
				t.check("nothing after the call ran", !outcome.values.includes(BigInt(AFTER)));
				t.check("the transaction reports the callee's error for the top-level instruction, index 0",
					outcome.raw.startsWith("TransactionErrorInstructionError { index: 0, "));
				t.check("the caller's last line repeats the callee's error",
					outcome.logs.at(-1).startsWith(`Program ${program} failed: ${reason}`));
			}
		}
		const second = await t.send("a failed call in the second instruction of a transaction",
			steps(step.call(0, [[1, 3], [2, 1]], transfer(2n * SOL), { carryOn: true })), passed, bySystem("custom 1"), "", { leading: 1 });
		t.check("the index is the top-level instruction's, 1", second.raw.startsWith("TransactionErrorInstructionError { index: 1, "));
		t.check("no lamports moved", t.svm.getAccount(pays).lamports === SOL && t.svm.getAccount(takes).lamports === SOL);
	});

	await scenario("a failed transaction", features, async (t) => {
		const SOL = 1_000_000_000n;
		const rent = (space) => t.svm.minimumBalanceForRentExemption(BigInt(space));
		const pays = t.put(await t.fresh(), { balance: SOL });
		const takes = t.put(await t.fresh(), { balance: SOL });
		const own = t.put(await t.fresh(), { data: new Uint8Array(8).fill(1), owner: program, balance: SOL });
		const made = await t.fresh();
		const passed = [t.meta(SYSTEM, false), t.meta(pays, true, true), t.meta(own, true), t.meta(takes, true), t.meta(made, true, true)];
		const stored = (account) => t.svm.getAccount(account);
		const untouched = () => stored(own).lamports === SOL && stored(own).data[0] === 1 && stored(own).data.length === 8
			&& stored(own).programAddress === program && stored(takes).lamports === SOL && stored(pays).lamports === SOL;
		const create = concat(u32(0), u64(rent(8)), u64(8), encoder.encode(program));
		const changes = [step.subtract(2, 5), step.add(3, 5), step.write(2, 0, 9), step.resize(2, 16)];
		const FAILED = byProbe("custom 7");
		await t.send("lamports moved, a byte written and the account grown, then an error", steps(...changes, step.fail(7)), passed, FAILED);
		t.check("every account reads as before", untouched());
		await t.send("an account created by a call, then an error",
			steps(step.call(0, [[1, 3], [4, 3]], create), step.fail(7)), passed, FAILED);
		t.check("the account does not exist", !stored(made).exists && untouched());
		await t.send("the account drained and given away, then an error",
			steps(step.subtract(2, SOL), step.add(3, SOL), step.resize(2, 0), step.assign(2, 0), step.fail(7)), passed, FAILED);
		t.check("every account reads as before", untouched());
		await t.send("changes, then a call that fails",
			steps(...changes, step.call(0, [[1, 3], [3, 1], [2, 1]], concat(u32(2), u64(2n * SOL)))), passed, bySystem("custom 1"));
		t.check("every account reads as before", untouched());
		await t.send("a call that moves lamports, then changes the runtime refuses",
			steps(step.call(0, [[1, 3], [3, 1]], concat(u32(2), u64(5))), step.add(2, 1)), passed, "UnbalancedInstruction by the transaction");
		t.check("every account reads as before", untouched());
		const returned = await t.send("return data set, then an error", steps(step.returns(4), step.fail(7)), passed, FAILED);
		t.check("the failed transaction still reports its 4 bytes of return data", returned.returned.length === 4);
		await t.send("the same changes with no error", steps(...changes), passed, OK);
		t.check("the changes are stored", stored(own).lamports === SOL - 5n && stored(own).data[0] === 9
			&& stored(own).data.length === 16 && stored(takes).lamports === SOL + 5n);
	});

	await scenario("rent", features, async (t) => {
		const SOL = 1_000_000_000n;
		const rent = (space) => t.svm.minimumBalanceForRentExemption(BigInt(space));
		const BELOW_RENT = "InsufficientFundsForRent by the transaction";
		const pays = t.put(await t.fresh(), { balance: SOL });
		const takes = t.put(await t.fresh(), { balance: SOL });
		const stored = (account) => t.svm.getAccount(account);
		const create = (amount, space, tag = 0) => concat(u32(tag), u64(amount), u64(space), encoder.encode(program));
		const transfer = (amount) => concat(u32(2), u64(amount));
		const programOwned = async (space, balance) => t.put(await t.fresh(), { data: new Uint8Array(space), owner: program, balance });
		const refusedFor = async (what, sent, passed, account) => {
			const outcome = await t.send(what, sent, passed, BELOW_RENT);
			t.check("the error names that account and no instruction", outcome.blamed === account && !outcome.raw.includes("InstructionError"));
			t.check("the program had succeeded", outcome.logs.at(-1) === `Program ${program} success`);
			return outcome;
		};
		for (const [name, tag] of [["CreateAccount", 0], ["CreateAccountAllowPrefund", 13]]) {
			const order = (payer, target) => tag === 0 ? [payer, target] : [target, payer];
			for (const space of [0, 8]) {
				const poor = await t.fresh();
				await refusedFor(`${name} of ${space} bytes for a lamport less than they need`,
					steps(step.call(0, order([1, 3], [2, 3]), create(rent(space) - 1n, space, tag))),
					[t.meta(SYSTEM, false), t.meta(pays, true, true), t.meta(poor, true, true)], poor);
				t.check("the account does not exist", !stored(poor).exists);
				await t.send(`${name} of ${space} bytes for exactly what they need`,
					steps(step.call(0, order([1, 3], [2, 3]), create(rent(space), space, tag))),
					[t.meta(SYSTEM, false), t.meta(pays, true, true), t.meta(await t.fresh(), true, true)], OK);
			}
		}
		const send = async (amount, to, expected) => {
			const passed = [t.meta(SYSTEM, false), t.meta(pays, true, true), t.meta(to, true)];
			const sent = steps(step.call(0, [[1, 3], [2, 1]], transfer(amount)));
			const what = `Transfer of ${amount === rent(0) ? "the rent of no bytes" : `${amount} lamport(s)`}`;
			if (expected === OK) return t.send(`${what} to an address that holds nothing`, sent, passed, OK);
			return refusedFor(`${what} to an address that holds nothing`, sent, passed, to);
		};
		await send(1n, await t.fresh(), BELOW_RENT);
		await send(rent(0) - 1n, await t.fresh(), BELOW_RENT);
		await send(rent(0), await t.fresh(), OK);
		const payerLeft = t.put(await t.fresh(), { balance: rent(0) + 10n });
		const draining = (amount) => steps(step.call(0, [[1, 3], [2, 1]], transfer(amount)));
		const drainedPassed = [t.meta(SYSTEM, false), t.meta(payerLeft, true, true), t.meta(takes, true)];
		await refusedFor("Transfer that leaves the payer a lamport below the rent of no bytes", draining(11n), drainedPassed, payerLeft);
		await t.send("Transfer that leaves the payer exactly the rent of no bytes", draining(10n), drainedPassed, OK);
		await t.send("Transfer of everything the payer holds", draining(rent(0)), drainedPassed, OK);
		t.check("the emptied payer does not exist", !stored(payerLeft).exists);

		const moving = (from, to, amount, ...more) => steps(step.subtract(from, amount), step.add(to, amount), ...more);
		const exact = await programOwned(8, rent(8));
		const exactPassed = [t.meta(SYSTEM, false), t.meta(exact, true), t.meta(takes, true)];
		await refusedFor("the program takes a lamport out of its account that holds exactly its rent", moving(1, 2, 1n), exactPassed, exact);
		await refusedFor("the program grows its account that holds exactly its rent", steps(step.resize(1, 9)), exactPassed, exact);
		await t.send("the program shrinks its account that holds exactly its rent", steps(step.resize(1, 4)), exactPassed, OK);
		const rich = await programOwned(8, SOL);
		const richPassed = [t.meta(SYSTEM, false), t.meta(rich, true), t.meta(takes, true)];
		await t.send("the program takes its account down to exactly its rent", moving(1, 2, SOL - rent(8)), richPassed, OK);
		await t.send("the program takes every lamport out of its account, data left in place", moving(1, 2, rent(8)), richPassed, OK);
		t.check("the emptied account does not exist: no lamports, no data, no owner", !stored(rich).exists);

		const bank = await programOwned(8, SOL);
		const INCINERATOR = address("1nc1nerator11111111111111111111111111111111");
		const below = async (what, sent, expected, space = 8) => {
			const poor = await programOwned(space, 1000n);
			const passed = [t.meta(SYSTEM, false), t.meta(poor, true), t.meta(takes, true), t.meta(bank, true)];
			const title = `an account already below its rent: ${what}`;
			return expected === OK ? t.send(title, sent, passed, OK) : refusedFor(title, sent, passed, poor);
		};
		await below("a byte written, lamports unchanged", steps(step.write(1, 0, 9)), OK);
		await below("a lamport taken out", moving(1, 2, 1n), OK);
		await below("a lamport added, still below", moving(3, 1, 1n), BELOW_RENT);
		await below("topped up to exactly its rent", moving(3, 1, rent(8) - 1000n), OK);
		await below("grown, lamports unchanged", steps(step.resize(1, 9)), BELOW_RENT);
		await below("shrunk, lamports unchanged", steps(step.resize(1, 4)), BELOW_RENT);
		await below("shrunk and a lamport taken out", moving(1, 2, 1n, step.resize(1, 4)), BELOW_RENT);
		const thin = t.put(await t.fresh(), { balance: 1000n });
		const thinPassed = [t.meta(SYSTEM, false), t.meta(pays, true, true), t.meta(thin, true)];
		await t.send("a wallet already below the rent of no bytes, passed writable and left alone", steps(), thinPassed, OK);
		await refusedFor("a wallet already below the rent of no bytes receives a lamport",
			steps(step.call(0, [[1, 3], [2, 1]], transfer(1n))), thinPassed, thin);
		await t.send("the incinerator receives a lamport",
			steps(step.call(0, [[1, 3], [2, 1]], transfer(1n))), [t.meta(SYSTEM, false), t.meta(pays, true, true), t.meta(INCINERATOR, true)], OK);
	});

	await scenario("the program's own writes", features, async (t) => {
		const SOL = 1_000_000_000n;
		const own = async (fill = 0) => t.put(await t.fresh(), { data: new Uint8Array(8).fill(fill), owner: program, balance: SOL });
		const foreign = async () => t.put(await t.fresh(), { data: new Uint8Array(8), owner: other, balance: SOL });
		const nothing = new Uint8Array([OP.nothing]);
		const OWN = 1, WALLET = 2, OWN_READ_ONLY = 3, FOREIGN = 4, FOREIGN_READ_ONLY = 5, OWN_SET = 6, PROGRAM = 7, CALLEE = 0;
		const AFTER = 5;
		const AT_ITS_END = "UnbalancedInstruction by the transaction";
		const does = async (what, sent, expected) => {
			const passed = [
				t.meta(other, false), t.meta(await own(), true), t.meta(t.put(await t.fresh(), { balance: SOL }), true),
				t.meta(await own(), false), t.meta(await foreign(), true), t.meta(await foreign(), false), t.meta(await own(7), true),
				t.meta(program, false),
			];
			const outcome = await t.send(what, sent, passed, expected === OK || expected === AT_ITS_END ? expected : byProbe(expected));
			if (expected !== OK) t.check("nothing after the refused step ran", !outcome.values.includes(BigInt(AFTER)));
			return outcome;
		};
		const moves = (from, to, ...more) => steps(step.subtract(from, 5), step.add(to, 5), ...more);
		const call = (metas, options) => step.call(CALLEE, metas, nothing, options);

		await does("a lamport added to its account", steps(step.add(OWN, 1)), AT_ITS_END);
		await does("a lamport taken out of its account", steps(step.subtract(OWN, 1)), AT_ITS_END);
		await does("lamports moved from its account to a wallet", moves(OWN, WALLET), OK);
		await does("lamports moved from its account to an account another program owns", moves(OWN, FOREIGN), OK);
		await does("lamports moved from a wallet to its account", moves(WALLET, OWN), "ExternalAccountLamportSpend");
		await does("lamports moved from its account to a read-only account", moves(OWN, FOREIGN_READ_ONLY), "ReadonlyLamportChange");
		await does("lamports moved from its read-only account", moves(OWN_READ_ONLY, OWN), "ReadonlyLamportChange");
		await does("lamports moved from a read-only account another program owns", moves(FOREIGN_READ_ONLY, OWN), "ExternalAccountLamportSpend");
		await does("lamports moved to the executable account of the callee", moves(OWN, CALLEE), "ReadonlyLamportChange");
		await does("a byte written in its account", steps(step.write(OWN, 0, 9)), OK);
		await does("a byte written in an account another program owns", steps(step.write(FOREIGN, 0, 9)), "ExternalAccountDataModified");
		await does("a byte written with the value it had in an account another program owns", steps(step.write(FOREIGN, 0, 0)), OK);
		await does("a byte written in its read-only account", steps(step.write(OWN_READ_ONLY, 0, 9)), "ReadonlyDataModified");
		await does("a byte written in a read-only account another program owns", steps(step.write(FOREIGN_READ_ONLY, 0, 9)), "ReadonlyDataModified");
		await does("its account of zero bytes given to another program", steps(step.assign(OWN, CALLEE)), OK);
		await does("its account given to the owner it has", steps(step.assign(OWN_SET, PROGRAM)), OK);
		await does("its account of bytes that are not zero given to another program", steps(step.assign(OWN_SET, CALLEE)), "ModifiedProgramId");
		await does("its account given away after a byte is written", steps(step.write(OWN, 0, 9), step.assign(OWN, CALLEE)), "ModifiedProgramId");
		await does("its read-only account given to another program", steps(step.assign(OWN_READ_ONLY, CALLEE)), "ModifiedProgramId");
		await does("an account another program owns taken for itself", steps(step.assign(FOREIGN, PROGRAM)), "ModifiedProgramId");
		await does("a wallet taken for itself", steps(step.assign(WALLET, PROGRAM)), "ModifiedProgramId");
		await does("its account grown", steps(step.resize(OWN, 16)), OK);
		await does("its account emptied of data", steps(step.resize(OWN, 0)), OK);
		await does("an account another program owns grown", steps(step.resize(FOREIGN, 16)), "ExternalAccountDataModified");
		await does("an account another program owns shrunk", steps(step.resize(FOREIGN, 4)), "ExternalAccountDataModified");
		await does("a wallet grown", steps(step.resize(WALLET, 8)), "ExternalAccountDataModified");
		await does("its read-only account grown", steps(step.resize(OWN_READ_ONLY, 16)), "ReadonlyDataModified");
		await does("lamports spent and a byte written in an account another program owns",
			steps(step.write(FOREIGN, 0, 9), step.subtract(FOREIGN, 5), step.add(OWN, 5)), "ExternalAccountLamportSpend");
		await does("a byte written in an account another program owns and the account taken",
			steps(step.assign(FOREIGN, PROGRAM), step.write(FOREIGN, 0, 9)), "ExternalAccountDataModified");
		await does("an account another program owns grown and a byte written",
			steps(step.write(FOREIGN, 0, 9), step.resize(FOREIGN, 16)), "ExternalAccountDataModified");
		await does("a lamport added to its account and a byte written in an account another program owns",
			steps(step.add(OWN, 1), step.write(FOREIGN, 0, 9)), "ExternalAccountDataModified");

		const W = WRITABLE;
		await does("lamports moved, then a call that receives both accounts", moves(OWN, WALLET, call([[OWN, W], [WALLET, W]])), OK);
		await does("lamports moved, then a call that receives both accounts read-only", moves(OWN, WALLET, call([[OWN, 0], [WALLET, 0]])), OK);
		await does("lamports moved, then a call that receives neither account", moves(OWN, WALLET, call([])), OK);
		await does("lamports moved, then a call that receives only the account they left",
			moves(OWN, WALLET, call([[OWN, W]], { carryOn: true }), step.log(AFTER)), "UnbalancedInstruction");
		await does("lamports moved, then a call that receives only the account they reached, read-only",
			moves(OWN, WALLET, call([[WALLET, 0]], { carryOn: true }), step.log(AFTER)), "UnbalancedInstruction");
		await does("a lamport added, a call that does not receive the account, the lamport taken back",
			steps(step.add(OWN, 1), call([]), step.subtract(OWN, 1)), OK);
		await does("a lamport added, a call that receives the account, the lamport taken back",
			steps(step.add(OWN, 1), call([[OWN, W]], { carryOn: true }), step.subtract(OWN, 1), step.log(AFTER)), "UnbalancedInstruction");
		await does("lamports moved out of a wallet, then a call that receives the wallet",
			moves(WALLET, OWN, call([[WALLET, W]], { carryOn: true }), step.log(AFTER)), "ExternalAccountLamportSpend");
		await does("lamports moved to a read-only account, then a call that receives both accounts",
			moves(OWN, FOREIGN_READ_ONLY, call([[OWN, W], [FOREIGN_READ_ONLY, 0]], { carryOn: true }), step.log(AFTER)), "ReadonlyLamportChange");
		await does("lamports taken out of a wallet, a call that does not receive it, the lamports put back",
			steps(step.subtract(WALLET, 5), call([]), step.add(WALLET, 5)), OK);
		await does("a byte written in an account another program owns, then a call that receives it read-only",
			steps(step.write(FOREIGN, 0, 9), call([[FOREIGN, 0]], { carryOn: true }), step.log(AFTER)), "ExternalAccountDataModified");
		await does("a byte written in an account another program owns, a call that does not receive it, the byte restored",
			steps(step.write(FOREIGN, 0, 9), call([[OWN, W]]), step.write(FOREIGN, 0, 0)), OK);
		await does("a byte written in its read-only account, then a call that receives it",
			steps(step.write(OWN_READ_ONLY, 0, 9), call([[OWN_READ_ONLY, 0]], { carryOn: true }), step.log(AFTER)), "ReadonlyDataModified");
		await does("an account another program owns taken, then a call that receives it",
			steps(step.assign(FOREIGN, PROGRAM), call([[FOREIGN, 0]], { carryOn: true }), step.log(AFTER)), "ModifiedProgramId");
		await does("an account another program owns grown, then a call that receives it",
			steps(step.resize(FOREIGN, 16), call([[FOREIGN, 0]], { carryOn: true }), step.log(AFTER)), "ExternalAccountDataModified");
		await does("a byte written in an account another program owns, then a call that marks it a signer",
			steps(step.write(FOREIGN, 0, 9), call([[FOREIGN, SIGNER]], { carryOn: true }), step.log(AFTER)), "PrivilegeEscalation");
		await does("its account given away, a call that receives it, then a byte written in it",
			steps(step.assign(OWN, CALLEE), call([[OWN, W]]), step.write(OWN, 0, 9)), "ExternalAccountDataModified");
		await does("its account given away, a call that does not receive it, then a byte written in it",
			steps(step.assign(OWN, CALLEE), call([]), step.write(OWN, 0, 9)), "ModifiedProgramId");
	});
	await scenario("refused by the runtime, not yet by the simulator", features, async (t) => {
		const SOL = 1_000_000_000n;
		const nothing = new Uint8Array([OP.nothing]);
		const own = t.put(await t.fresh(), { data: new Uint8Array(8).fill(0x61), owner: program, balance: SOL });
		const wallet = t.put(await t.fresh(), { balance: SOL });
		const passed = [t.meta(other, false), t.meta(own, true), t.meta(wallet, true)];
		const CALLEE = 0, OWN = 1, WALLET = 2;
		const BY_THE_TRANSACTION = (error) => `${error} by the transaction`;
		await t.send("a call to an account that is not a program",
			steps(step.call(WALLET, [], nothing)), passed, byProbe("UnsupportedProgramId"));
		await t.send("a call that marks an account the caller holds unsigned a signer, to a program the simulator does not run",
			steps(step.call(CALLEE, [[WALLET, SIGNER]], nothing)), passed, ESCALATED);
		const calls = (count) => steps(...Array.from({ length: count }, () => step.call(CALLEE, [], nothing)));
		await t.send("63 calls in one instruction", calls(63), passed, OK);
		await t.send("64 calls in one instruction", calls(64), passed, BY_THE_TRANSACTION("MaxInstructionTraceLengthExceeded"));
		const logged = (lines) => concat(new Uint8Array([OP.logAccountData]), u16(1), u16(lines));
		await t.send("1000 log lines of one byte", logged(1000), [t.meta(own, false)], OK);
		await t.send("3000 log lines of one byte", logged(3000), [t.meta(own, false)], BY_THE_TRANSACTION("ComputationalBudgetExceeded"));
		const nested = (depth) => depth === 0 ? nothing : steps(step.call(0, [[0, 0]], nested(depth - 1)));
		await t.send("a call nested 4 deep under the instruction", steps(step.call(CALLEE, [[CALLEE, 0]], nested(3))), passed, OK);
		await t.send("a call nested 5 deep under the instruction", steps(step.call(CALLEE, [[CALLEE, 0]], nested(4))), passed, "CallDepth by the callee");
	});
}

if (failures > 0) {
	console.error(`${failures} check(s) failed`);
	process.exit(1);
}
console.log("host fidelity against the real runtime and System program: every check passed");
