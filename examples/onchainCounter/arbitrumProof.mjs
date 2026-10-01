import { readFileSync, writeFileSync, renameSync, openSync, closeSync, unlinkSync } from "node:fs";
import { resolve } from "node:path";
import { spawn, execFileSync } from "node:child_process";
import { parseArgs } from "node:util";
import { createInterface } from "node:readline/promises";
import {
	encodeDeployData, encodeFunctionData, decodeAbiParameters, getAddress,
	getContractAddress, toHex, formatEther,
} from "viem";
import {
	chainId, defaultRpc, arbWasm, arbWasmAbi, compileCaller, loadArtifact,
	connect, activeVersion, quoteActivation, readCounter, callerRuntime,
} from "./arbitrumClient.mjs";

const names = ["deploy-program", "activate", "deploy-caller", "increment-7", "increment-5", "rejections", "boundary", "limit-rejection"];
const states = [null, 0n, 0n, 7n, 12n, 12n, 1000000n, 1000000n];
const usage = `node arbitrumProof.mjs doctor [--rpc URL]
node arbitrumProof.mjs prepare WASM PUBLIC_ADDRESS RECORD.json [--rpc URL]
node arbitrumProof.mjs simulate RECORD.json
node arbitrumProof.mjs next RECORD.json
node arbitrumProof.mjs record RECORD.json TRANSACTION_HASH
node arbitrumProof.mjs cancel RECORD.json
node arbitrumProof.mjs verify RECORD.json

prepare/simulate/verify are read-only onchain. next requests consent for ONE transaction,
then opens cast's browser wallet. Repeat next for the next step. record recovers a known
wallet transaction after interruption; cancel is only for a rejected, unsent request.
Only Arbitrum Sepolia (421614). No private-key or automatic-signing options.`;
const json = (value) => JSON.stringify(value, (_, item) => typeof item === "bigint" ? item.toString() : item, 2);
const { values, positionals } = parseArgs({ options: { rpc: { type: "string" }, help: { type: "boolean" } }, allowPositionals: true });
const [command, ...args] = positionals;
let proof;
let recordPath;

function save() {
	const temporary = `${recordPath}.${process.pid}.tmp`;
	writeFileSync(temporary, `${json(proof)}\n`, { flag: "wx" });
	renameSync(temporary, recordPath);
}

function sameAddress(left, right) {
	return (left ?? "").toLowerCase() === (right ?? "").toLowerCase();
}

async function consent(text) {
	if (!process.stdin.isTTY) throw new Error("Interactive consent required; no unattended broadcast or cancellation");
	const terminal = createInterface({ input: process.stdin, output: process.stdout });
	try {
		if (await terminal.question(`Type '${text}' to continue: `) !== text) throw new Error("Not approved; no action taken");
	} finally {
		terminal.close();
	}
}

function callData(compiled, functionName, args = []) {
	return encodeFunctionData({ abi: compiled.contracts.CounterCaller.abi, functionName, args });
}

function requestFor(index, context, artifact, compiled) {
	const base = { from: proof.from, value: "0" };
	switch (index) {
		case 0: return { ...base, to: null, data: artifact.initCode };
		case 1: return { ...base, to: arbWasm, data: encodeFunctionData({ abi: arbWasmAbi, functionName: "activateProgram", args: [context.program] }) };
		case 2: return { ...base, to: null, data: encodeDeployData({ abi: compiled.contracts.CounterCaller.abi, bytecode: `0x${compiled.contracts.CounterCaller.evm.bytecode.object}`, args: [context.program] }) };
		case 3: return { ...base, to: context.caller, data: callData(compiled, "incrementAndCheck", [7n, 0n, 7n]) };
		case 4: return { ...base, to: context.caller, data: callData(compiled, "incrementAndCheck", [5n, 7n, 12n]) };
		case 5: return { ...base, to: context.caller, data: callData(compiled, "proveRejections") };
		case 6: return { ...base, to: context.caller, data: callData(compiled, "incrementAndCheck", [999988n, 12n, 1000000n]) };
		case 7: return { ...base, to: context.caller, data: callData(compiled, "proveLimit") };
		default: throw new Error(`Unknown proof step: ${index}`);
	}
}

async function verifySteps(client, artifact, compiled) {
	const context = {};
	for (let index = 0; index < proof.steps.length; index++) {
		const step = proof.steps[index];
		if (step.name !== names[index]) throw new Error(`Unexpected proof step ${index}: ${step.name}`);
		let blockNumber;
		if (step.kind === "active-code-observation" && index === 1) {
			blockNumber = BigInt(step.blockNumber);
			if (blockNumber < context.deployedAt) throw new Error("Activation observation predates deployment");
		} else {
			if (step.kind !== "transaction") throw new Error(`Invalid evidence kind: ${step.kind}`);
			const receipt = await client.getTransactionReceipt({ hash: step.hash });
			const transaction = await client.getTransaction({ hash: step.hash });
			const expected = requestFor(index, context, artifact, compiled);
			if (receipt.status !== "success") throw new Error(`${step.name} reverted: ${step.hash}`);
			if (!sameAddress(transaction.from, proof.from) || !sameAddress(transaction.to, expected.to)
				|| transaction.input !== expected.data || Number(transaction.chainId) !== chainId
				|| transaction.value !== BigInt(step.request.value) || (index !== 1 && transaction.value !== 0n)) {
				throw new Error(`Transaction does not match ${step.name}: ${step.hash}`);
			}
			blockNumber = receipt.blockNumber;
			const block = await client.getBlock({ blockNumber });
			if (block.hash !== receipt.blockHash) throw new Error(`Noncanonical receipt: ${step.hash}`);
			step.receipt = receipt;
			step.transaction = transaction;
			if (index === 0 || index === 2) {
				if (!receipt.contractAddress) throw new Error(`Missing deployed address: ${step.hash}`);
				const address = receipt.contractAddress;
				const actualCode = await client.getCode({ address, blockNumber });
				const expectedCode = index === 0 ? artifact.code : callerRuntime(compiled.contracts.CounterCaller, context.program);
				if (actualCode !== expectedCode) throw new Error(`Deployed bytecode mismatch: ${address}`);
				if (index === 0) { context.program = address; context.deployedAt = blockNumber; }
				else context.caller = address;
			}
		}
		if (index === 1) {
			const version = await activeVersion(client, artifact.codeHash, blockNumber);
			if (version === null) throw new Error("Deployed WASM is not activated");
			step.stylusVersion = version;
		}
		if (states[index] !== null) {
			const value = await readCounter(client, context.program, blockNumber);
			if (value !== states[index]) throw new Error(`${step.name}: expected ${states[index]}, read ${value}`);
			step.readback = { method: "eth_call get()", blockNumber, value };
		}
	}
	proof.confirmed = {
		scope: "Arbitrum Sepolia L2 receipts; not L1 finality",
		complete: proof.steps.length === names.length,
		program: context.program ?? null, caller: context.caller ?? null,
		transactions: proof.steps.filter((step) => step.kind === "transaction").length,
	};
	return context;
}

async function recordPending(client, artifact, compiled, hash) {
	if (!proof.pending) throw new Error("No pending transaction to record");
	if (!/^0x[0-9a-fA-F]{64}$/.test(hash)) throw new Error("Expected a transaction hash");
	const pending = proof.pending;
	const transaction = await client.getTransaction({ hash });
	if (!sameAddress(transaction.from, pending.request.from) || !sameAddress(transaction.to, pending.request.to)
		|| transaction.input !== pending.request.data || transaction.value !== BigInt(pending.request.value)
		|| transaction.nonce !== pending.request.nonce || Number(transaction.chainId) !== chainId) {
		throw new Error("Wallet transaction differs from approved request; pending request retained");
	}
	pending.hash = hash;
	save();
	const receipt = await client.waitForTransactionReceipt({ hash, confirmations: 1, timeout: 120000 });
	pending.receipt = receipt;
	save();
	if (receipt.status !== "success") throw new Error(`Transaction reverted; evidence retained: ${hash}`);
	proof.steps.push({ ...pending, kind: "transaction" });
	proof.pending = null;
	await verifySteps(client, artifact, compiled);
	save();
}

async function browserSend(request) {
	const args = ["send", "--browser", "--async", "--color", "never", "--rpc-url", proof.rpc,
		"--chain", String(chainId), "--from", proof.from, "--nonce", String(request.nonce),
		"--gas-limit", request.gas, "--gas-price", request.maxFeePerGas, "--priority-gas-price", "0",
		"--value", request.value];
	if (request.to) args.push(request.to, request.data);
	else args.push("--create", request.data);
	const env = Object.fromEntries(Object.entries(process.env).filter(([name]) => !name.startsWith("ETH_") && !name.startsWith("CAST_")));
	const child = spawn("cast", args, { stdio: ["inherit", "pipe", "inherit"], env });
	let output = "";
	child.stdout.on("data", (chunk) => { output += chunk; process.stdout.write(chunk); });
	await new Promise((accept, reject) => {
		child.on("error", reject);
		child.on("close", (code) => code === 0 ? accept() : reject(new Error(`cast exited ${code}; request retained, no automatic resubmission`)));
	});
	const hashes = output.split(/\r?\n/).map((line) => line.trim()).filter((line) => /^0x[0-9a-fA-F]{64}$/.test(line));
	if (hashes.length !== 1) throw new Error("No unambiguous transaction hash; use record with the wallet's hash");
	return hashes[0];
}

async function run() {
	if (values.help || !command) { console.log(usage); return; }
	const counts = { doctor: 0, prepare: 3, simulate: 1, next: 1, record: 2, cancel: 1, verify: 1 };
	if (!(command in counts) || args.length !== counts[command]) throw new Error(usage);
	if (values.rpc && !["doctor", "prepare"].includes(command)) throw new Error("RPC is pinned in the proof record; --rpc is only for doctor/prepare");
	const compiled = compileCaller();
	if (command === "doctor") {
		const client = await connect(values.rpc ?? defaultRpc);
		const version = await client.readContract({ address: arbWasm, abi: arbWasmAbi, functionName: "stylusVersion" });
		console.log(json({ chainId, stylusVersion: version, solc: compiled.compiler,
			callerCreationBytes: compiled.contracts.CounterCaller.evm.bytecode.object.length / 2,
			cargoStylus: execFileSync("cargo", ["stylus", "--version"], { encoding: "utf8" }).trim(),
			cast: execFileSync("cast", ["--version"], { encoding: "utf8" }).split("\n")[0],
			scope: "tooling and read-only RPC only; no MetaScript WASM execution" }));
		return;
	}
	if (command === "prepare") {
		const artifact = loadArtifact(args[0]);
		const from = getAddress(args[1]);
		recordPath = resolve(args[2]);
		const client = await connect(values.rpc ?? defaultRpc);
		const sdkOutput = execFileSync("cargo", ["stylus", "check", "--wasm-file", artifact.path, "--endpoint", values.rpc ?? defaultRpc], { encoding: "utf8", maxBuffer: 16 * 1024 * 1024 });
		const nonce = await client.getTransactionCount({ address: from, blockTag: "pending" });
		const program = getContractAddress({ from, nonce: BigInt(nonce) });
		const activationQuote = await quoteActivation(client, artifact, from, program);
		proof = { schema: 1, chainId, rpc: values.rpc ?? defaultRpc, from, createdAt: new Date().toISOString(),
			artifact, solidity: { sourceSha256: compiled.sourceSha256, compiler: compiled.compiler },
			sdkCheck: { output: sdkOutput, scope: "cargo-stylus normalized WASM check" },
			activationQuote: { ...activationQuote, scope: "eth_call using exact packaged bytes, with balance/code overrides" },
			simulation: null, steps: [], pending: null, confirmed: { complete: false } };
		writeFileSync(recordPath, `${json(proof)}\n`, { flag: "wx" });
		console.log(`Prepared ${recordPath}; no transaction sent. Run simulate next.`);
		return;
	}
	recordPath = resolve(args[0]);
	const lockPath = `${recordPath}.lock`;
	const lock = openSync(lockPath, "wx");
	try {
		proof = JSON.parse(readFileSync(recordPath, "utf8"));
		if (proof.schema !== 1 || proof.chainId !== chainId) throw new Error("Unsupported proof schema or chain");
		const artifact = loadArtifact(proof.artifact.path);
		if (artifact.sha256 !== proof.artifact.sha256 || artifact.codeHash !== proof.artifact.codeHash
			|| compiled.sourceSha256 !== proof.solidity.sourceSha256 || compiled.compiler !== proof.solidity.compiler) {
			throw new Error("Artifact or Solidity consumer changed; prepare a new proof record");
		}
		const client = await connect(proof.rpc);
		const context = await verifySteps(client, artifact, compiled);
		if (command === "verify") {
			save();
			console.log(json({ simulation: proof.simulation, confirmed: proof.confirmed, next: names[proof.steps.length] ?? null }));
			if (!proof.confirmed.complete) process.exitCode = 2;
			return;
		}
		if (command === "simulate") {
			const contract = compiled.contracts.CounterSimulation;
			const data = encodeDeployData({ abi: contract.abi, bytecode: `0x${contract.evm.bytecode.object}`, args: [artifact.initCode] });
			const blockNumber = await client.getBlockNumber();
			const params = [{ from: proof.from, data, value: toHex(10n ** 18n), gas: toHex(30000000) }, toHex(blockNumber), { [proof.from]: { balance: toHex(100n * 10n ** 18n) } }];
			proof.simulation = { scope: "Nitro eth_call with balance override; no broadcast, no cross-transaction persistence", passed: false, blockNumber, request: { method: "eth_call", params } };
			save();
			const result = await client.request({ method: "eth_call", params });
			const [program, caller, version, fee, finalValue] = decodeAbiParameters([{ type: "address" }, { type: "address" }, { type: "uint16" }, { type: "uint256" }, { type: "uint64" }], result);
			if (finalValue !== 1000000n || version === 0) throw new Error("Unexpected Nitro simulation result");
			Object.assign(proof.simulation, { passed: true, result, program, caller, version, fee, finalValue });
			save();
			console.log(json(proof.simulation));
			return;
		}
		if (command === "record") { await recordPending(client, artifact, compiled, args[1]); return; }
		if (command === "cancel") {
			if (!proof.pending || proof.pending.hash) throw new Error("Only an unsent request without a transaction hash can be cancelled");
			const nonce = await client.getTransactionCount({ address: proof.from, blockTag: "pending" });
			if (nonce !== proof.pending.request.nonce) throw new Error("Account nonce changed; locate the transaction in the wallet instead");
			await consent("I rejected this request in my wallet");
			(proof.cancelledRequests ??= []).push(proof.pending);
			proof.pending = null;
			save();
			return;
		}
		if (proof.pending) {
			if (!proof.pending.hash) throw new Error("Unresolved wallet request: use record with its hash, or cancel only if rejected; nothing resent");
			await recordPending(client, artifact, compiled, proof.pending.hash);
			return;
		}
		const index = proof.steps.length;
		if (index === names.length) { console.log(json(proof.confirmed)); return; }
		if (!proof.simulation?.passed) throw new Error("Run the real Nitro simulation successfully before requesting signatures");
		const request = requestFor(index, context, artifact, compiled);
		if (index === 1) {
			const quote = await quoteActivation(client, artifact, proof.from, context.program);
			if (quote.alreadyActive) {
				proof.steps.push({ name: names[index], kind: "active-code-observation", blockNumber: quote.blockNumber });
				await verifySteps(client, artifact, compiled);
				save();
				console.log("Exact deployed code is already activated; recorded RPC observation, not a fabricated activation transaction.");
				return;
			}
			request.value = (quote.fee * 120n / 100n + 1n).toString();
		}
		request.nonce = await client.getTransactionCount({ address: proof.from, blockTag: "pending" });
		const estimate = await client.estimateGas({ account: proof.from, to: request.to ?? undefined, data: request.data, value: BigInt(request.value) });
		request.gas = (estimate * 120n / 100n + 1n).toString();
		request.maxFeePerGas = ((await client.getGasPrice()) * 2n).toString();
		const maximum = BigInt(request.value) + BigInt(request.gas) * BigInt(request.maxFeePerGas);
		const balance = await client.getBalance({ address: proof.from });
		if (balance < maximum) throw new Error(`Insufficient testnet ETH: balance ${formatEther(balance)}, maximum ${formatEther(maximum)}`);
		console.log(json({ step: names[index], network: "Arbitrum Sepolia", chainId, from: proof.from, to: request.to ?? "CREATE",
			artifactSha256: artifact.sha256, valueWei: request.value, gasLimit: request.gas,
			maxFeePerGasWei: request.maxFeePerGas, maximumTotalETH: formatEther(maximum) }));
		await consent(`send ${names[index]}`);
		proof.pending = { name: names[index], request };
		save();
		const hash = await browserSend(request);
		proof.pending.hash = hash;
		save();
		await recordPending(client, artifact, compiled, hash);
		console.log(json({ confirmed: proof.confirmed, next: names[proof.steps.length] ?? null }));
	} catch (error) {
		if (proof) {
			proof.confirmed = { complete: false };
			proof.lastError = { message: error.message, at: new Date().toISOString() };
			save();
		}
		throw error;
	} finally {
		closeSync(lock);
		unlinkSync(lockPath);
	}
}

run().catch((error) => {
	console.error(error.shortMessage ?? error.message);
	process.exitCode = 1;
});
