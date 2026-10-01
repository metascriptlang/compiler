import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { createHash } from "node:crypto";
import { brotliCompressSync, constants } from "node:zlib";
import solc from "solc";
import {
	createPublicClient, http, keccak256, parseAbi, encodeFunctionData,
	decodeFunctionResult, ContractFunctionRevertedError, toHex,
} from "viem";
import { arbitrumSepolia } from "viem/chains";

export const chainId = 421614;
export const defaultRpc = "https://sepolia-rollup.arbitrum.io/rpc";
export const arbWasm = "0x0000000000000000000000000000000000000071";
export const arbWasmAbi = parseAbi([
	"function activateProgram(address program) payable returns (uint16 version, uint256 fee)",
	"function codehashVersion(bytes32 codehash) view returns (uint16 version)",
	"function stylusVersion() view returns (uint16 version)",
	"error ProgramNotActivated()",
	"error ProgramNeedsUpgrade(uint16 version, uint16 stylusVersion)",
	"error ProgramExpired(uint64 ageInSeconds)",
]);
export const counterAbi = parseAbi(["function get() view returns (uint64)"]);

export function sha256(bytes) {
	return createHash("sha256").update(bytes).digest("hex");
}

export function compileCaller() {
	const source = readFileSync(new URL("./counterCaller.sol", import.meta.url), "utf8");
	const input = {
		language: "Solidity",
		sources: { "counterCaller.sol": { content: source } },
		settings: {
			optimizer: { enabled: true, runs: 200 }, evmVersion: "cancun",
			outputSelection: { "*": { "*": ["abi", "evm.bytecode.object", "evm.deployedBytecode.object", "evm.deployedBytecode.immutableReferences"] } },
		},
	};
	const compiled = JSON.parse(solc.compile(JSON.stringify(input)));
	const errors = (compiled.errors ?? []).filter((error) => error.severity === "error");
	if (errors.length) throw new Error(errors.map((error) => error.formattedMessage).join("\n"));
	return { sourceSha256: sha256(source), compiler: solc.version(), contracts: compiled.contracts["counterCaller.sol"] };
}

export function loadArtifact(path) {
	const wasm = readFileSync(path);
	const module = new WebAssembly.Module(wasm);
	const imports = WebAssembly.Module.imports(module);
	const exports = WebAssembly.Module.exports(module);
	if (imports.some((entry) => entry.module !== "vm_hooks" || entry.kind !== "function")) {
		throw new Error(`Non-Stylus imports: ${JSON.stringify(imports)}`);
	}
	for (const [name, kind] of [["user_entrypoint", "function"], ["memory", "memory"]]) {
		if (!exports.some((entry) => entry.name === name && entry.kind === kind)) {
			throw new Error(`Missing Stylus export: ${name} (${kind})`);
		}
	}
	const compressed = brotliCompressSync(wasm, { params: { [constants.BROTLI_PARAM_QUALITY]: 11 } });
	const code = `0xeff00000${compressed.toString("hex")}`;
	const length = (compressed.length + 4).toString(16).padStart(64, "0");
	return {
		path: resolve(path), sha256: sha256(wasm), wasmBytes: wasm.length,
		code, codeHash: keccak256(code), compressedBytes: compressed.length + 4,
		initCode: `0x7f${length}80602b6000396000f300${code.slice(2)}`,
		imports, exports,
	};
}

export async function connect(rpc) {
	const client = createPublicClient({ chain: arbitrumSepolia, transport: http(rpc, { retryCount: 0, timeout: 120000 }) });
	const actual = await client.getChainId();
	if (actual !== chainId) throw new Error(`Refusing chain ${actual}; expected Arbitrum Sepolia ${chainId}`);
	return client;
}

export async function activeVersion(client, codeHash, blockNumber) {
	try {
		return await client.readContract({ address: arbWasm, abi: arbWasmAbi, functionName: "codehashVersion", args: [codeHash], blockNumber });
	} catch (error) {
		const revert = error.walk?.((cause) => cause instanceof ContractFunctionRevertedError);
		if (["ProgramNotActivated", "ProgramNeedsUpgrade", "ProgramExpired"].includes(revert?.data?.errorName)) return null;
		throw error;
	}
}

export async function quoteActivation(client, artifact, from, program) {
	const blockNumber = await client.getBlockNumber();
	const version = await activeVersion(client, artifact.codeHash, blockNumber);
	if (version !== null) return { blockNumber, version, fee: 0n, alreadyActive: true };
	const result = await client.request({
		method: "eth_call",
		params: [{
			from, to: arbWasm, value: toHex(10n ** 18n),
			data: encodeFunctionData({ abi: arbWasmAbi, functionName: "activateProgram", args: [program] }),
		}, toHex(blockNumber), {
			[from]: { balance: toHex(100n * 10n ** 18n) },
			[program]: { code: artifact.code },
		}],
	});
	const [activatedVersion, fee] = decodeFunctionResult({ abi: arbWasmAbi, functionName: "activateProgram", data: result });
	return { blockNumber, version: activatedVersion, fee, alreadyActive: false };
}

export async function readCounter(client, program, blockNumber) {
	return client.readContract({ address: program, abi: counterAbi, functionName: "get", blockNumber });
}

export function callerRuntime(compiled, program) {
	const runtime = compiled.evm.deployedBytecode;
	const bytes = Buffer.from(runtime.object, "hex");
	for (const locations of Object.values(runtime.immutableReferences)) {
		for (const { start, length } of locations) {
			if (length !== 32) throw new Error(`Unexpected Solidity immutable width: ${length}`);
			Buffer.from(program.slice(2).padStart(64, "0"), "hex").copy(bytes, start);
		}
	}
	return `0x${bytes.toString("hex")}`;
}
