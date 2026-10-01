import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { resolve, join } from "node:path";
import { fileURLToPath } from "node:url";
import { execFileSync } from "node:child_process";
import { parseArgs } from "node:util";
import { encodeFunctionData, decodeFunctionResult, getContractAddress, toHex, hexToBytes } from "viem";
import { chainId, arbWasm, arbWasmAbi, connect, activeVersion, loadArtifact, sha256 } from "./arbitrumClient.mjs";

const root = fileURLToPath(new URL("../../", import.meta.url));
const usage = "node arbitrumConsole.mjs SOURCE.ms OUTPUT_DIRECTORY --msc COMPILER --cc CLANG [--rpc URL] [--demo]";
const json = (value) => JSON.stringify(value, (_, item) => typeof item === "bigint" ? item.toString() : item, 2);

async function run() {
	const { values, positionals } = parseArgs({ options: {
		msc: { type: "string" }, cc: { type: "string" }, rpc: { type: "string", default: "https://arbitrum-sepolia-rpc.publicnode.com" }, help: { type: "boolean" },
		demo: { type: "boolean" },
	}, allowPositionals: true });
	if (values.help) { console.log(usage); return; }
	if (positionals.length !== 2 || !values.msc || !values.cc) throw new Error(usage);
	const source = resolve(positionals[0]);
	const output = resolve(positionals[1]);
	if (!source.endsWith(".ms")) throw new Error("Expected a .ms entry module");
	const compiler = resolve(values.msc);
	const originalHash = sha256(readFileSync(source));
	mkdirSync(output, { recursive: true });
	const proofPath = join(output, "proof.json");
	const entry = join(output, "entry.ms");
	const wasm = join(output, "program.wasm");
	const proof = {
		scope: "Nitro eth_simulateV1; unsigned ephemeral transactions, not a public deployment",
		chainId, rpc: values.rpc, source, sourceSha256: originalHash, passed: false,
	};
	writeFileSync(proofPath, `${json(proof)}\n`, { flag: "wx" });
	try {
		writeFileSync(entry, `import ${JSON.stringify(source.slice(0, -3))};\nimport { Word, fromUint64, returnWord } from "std/arbitrum";\n\nWord.fromUint64(0).returnWord();\n`, { flag: "wx" });
		const command = ["build", entry, "--os=bare", "--cpu=wasm32", "--gc=manual", "--app=lib", `--cc=${values.cc}`, "--release", `--output=${wasm}`];
		proof.build = { compiler, args: command };
		const build = execFileSync(compiler, command, { cwd: root, encoding: "utf8", maxBuffer: 16 * 1024 * 1024 });
		writeFileSync(join(output, "build.log"), build);
		const artifact = loadArtifact(wasm);
		proof.artifact = artifact;
		console.log(values.demo
			? `   program.wasm  ${artifact.wasmBytes} bytes  (${artifact.compressedBytes} bytes packaged)`
			: `WASM: ${artifact.wasmBytes} bytes · packaged: ${artifact.compressedBytes} bytes · SHA-256 ${artifact.sha256}`);
		proof.sdkCheck = execFileSync("cargo", ["stylus", "check", "--wasm-file", wasm, "--endpoint", values.rpc], { cwd: root, encoding: "utf8", maxBuffer: 16 * 1024 * 1024 });
		const client = await connect(values.rpc);
		const blockNumber = await client.getBlockNumber();
		const from = "0x1234567890123456789012345678901234567890";
		const program = getContractAddress({ from, nonce: 0n });
		const version = await activeVersion(client, artifact.codeHash, blockNumber);
		const base = { from, value: "0x0", gas: toHex(30000000), maxFeePerGas: "0x0", maxPriorityFeePerGas: "0x0" };
		const calls = [{ ...base, input: artifact.initCode }];
		if (version === null) {
			calls.push({ ...base, to: arbWasm, value: toHex(10n ** 18n), input: encodeFunctionData({ abi: arbWasmAbi, functionName: "activateProgram", args: [program] }) });
		}
		const invocationStart = calls.length;
		calls.push({ ...base, to: program, input: "0x" }, { ...base, to: program, input: "0x" });
		proof.request = {
			method: "eth_simulateV1",
			params: [{ blockStateCalls: [{ stateOverrides: { [from]: { balance: toHex(100n * 10n ** 18n), nonce: "0x0" } }, calls }], validation: false, traceTransfers: false }, toHex(blockNumber)],
		};
		const heading = `3 — execute on Nitro (unsigned simulation, Arbitrum Sepolia ${chainId}, block ${blockNumber})`;
		console.log(values.demo ? `\n\u001b[1;36m▸ ${heading}\u001b[0m` : heading);
		console.log(`   deploy → ${version === null ? "activate → " : "already-active codehash → "}invoke twice; no broadcast or persisted deployment`);
		writeFileSync(proofPath, `${json(proof)}\n`);
		const result = await client.request(proof.request);
		proof.response = result;
		if (result.length !== 1 || result[0].calls.length !== calls.length) throw new Error("Unexpected simulation receipt count");
		for (const [index, call] of result[0].calls.entries()) {
			if (call.status !== "0x1") throw new Error(`Simulation call ${index} failed: ${json(call)}`);
		}
		if (version === null) {
			const [activatedVersion, fee] = decodeFunctionResult({ abi: arbWasmAbi, functionName: "activateProgram", data: result[0].calls[1].returnData });
			proof.activation = { version: activatedVersion, fee };
		} else proof.activation = { version, alreadyActive: true };
		const decoder = new TextDecoder("utf-8", { fatal: true });
		const invocations = result[0].calls.slice(invocationStart).map((call) => {
			if (call.returnData !== `0x${"0".repeat(64)}`) throw new Error(`Unexpected adapter return data: ${call.returnData}`);
			return {
				gasUsed: call.gasUsed,
				lines: call.logs.map((log) => {
					if (log.address.toLowerCase() !== program.toLowerCase() || log.topics.length !== 0) throw new Error("Unexpected console event emitter or topics");
					return decoder.decode(hexToBytes(log.data));
				}),
			};
		});
		if (sha256(readFileSync(source)) !== originalHash) throw new Error("Source changed during proof");
		proof.invocations = invocations;
		proof.passed = true;
		writeFileSync(proofPath, `${json(proof)}\n`);
		for (const [index, invocation] of invocations.entries()) {
			if (values.demo && index > 0 && json(invocation.lines) === json(invocations[0].lines)) {
				console.log(`Repeat invocation: identical console output · simulated gas ${BigInt(invocation.gasUsed)}`);
				continue;
			}
			console.log(`Invocation ${index + 1}: ${invocation.lines.length} console events · simulated gas ${BigInt(invocation.gasUsed)}`);
			for (const line of invocation.lines) console.log(line);
		}
		console.log(`Execution recorded in ${proofPath}; program-specific output assertions belong to the consumer.`);
	} catch (error) {
		proof.error = error.shortMessage ?? error.message;
		writeFileSync(proofPath, `${json(proof)}\n`);
		throw error;
	}
}

run().catch((error) => { console.error(error.shortMessage ?? error.message); process.exitCode = 1; });
