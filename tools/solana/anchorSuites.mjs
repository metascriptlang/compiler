import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { FeatureSet } from "litesvm";
import { address, getAddressEncoder, getBase58Encoder, getProgramDerivedAddress, lamports } from "@solana/kit";

export const SYSTEM = address("11111111111111111111111111111111");
export const encoder = getAddressEncoder();
const base58 = getBase58Encoder();
const features = JSON.parse(readFileSync(new URL("./mainnetInactiveFeatures.json", import.meta.url), "utf8"));

export function u64(value) {
	const bytes = new Uint8Array(8);
	new DataView(bytes.buffer).setBigUint64(0, BigInt(value), true);
	return bytes;
}

export function concat(...parts) {
	const out = new Uint8Array(parts.reduce((total, part) => total + part.length, 0));
	let offset = 0;
	for (const part of parts) {
		out.set(part, offset);
		offset += part.length;
	}
	return out;
}

export const anchorTag = (name) => new Uint8Array(createHash("sha256").update("global:" + name).digest().subarray(0, 8));
export const byteTag = (n) => new Uint8Array([n]);
export const accountTag = (name) => new Uint8Array(createHash("sha256").update("account:" + name).digest().subarray(0, 8));

export async function nestedAccounts(ctx, initialized) {
	const [config, configBump] = await getProgramDerivedAddress({ programAddress: ctx.programId, seeds: ["config"] });
	const [counter, counterBump] = await getProgramDerivedAddress({ programAddress: ctx.programId, seeds: ["counter"] });
	if (initialized) {
		const configData = new Uint8Array(48);
		configData.set(accountTag("Config"));
		configData.set(encoder.encode(ctx.payer.address), 8);
		configData[40] = configBump;
		const counterData = new Uint8Array(24);
		counterData.set(accountTag("Counter"));
		counterData.set(u64(41), 8);
		counterData[16] = counterBump;
		for (const [key, data] of [[config, configData], [counter, counterData]]) {
			ctx.svm.setAccount({ address: key, data, executable: false, lamports: lamports(10_000_000n), programAddress: ctx.programId, space: BigInt(data.length) });
		}
	}
	return { config, counter };
}

export function nestedCounterCheck(ctx, config, counter, expected) {
	const settings = ctx.svm.getAccount(config);
	const value = ctx.svm.getAccount(counter);
	if (!settings || !value || settings.data.length !== 48 || value.data.length !== 24) throw new Error("nested account sizes differ");
	if (new DataView(value.data.buffer, value.data.byteOffset, value.data.length).getBigUint64(8, true) !== BigInt(expected)) throw new Error("nested counter differs");
	if (Buffer.compare(Buffer.from(settings.data.subarray(8, 40)), Buffer.from(encoder.encode(ctx.payer.address))) !== 0) throw new Error("nested admin differs");
}

export function mainnetFeatures() {
	const set = FeatureSet.allEnabled();
	for (const id of features.inactive) set.deactivate(new Uint8Array(base58.encode(id)));
	return set;
}

export async function oracleAccounts(ctx, initialized, fixedAuthority = false) {
	const oracleSigner = await ctx.signer(12);
	const authority = fixedAuthority ? await ctx.signer(7) : ctx.payer;
	if (initialized) {
		const data = new Uint8Array(48);
		data.set(accountTag("Oracle"));
		data.set(encoder.encode(ctx.payer.address), 8);
		ctx.svm.setAccount({ address: oracleSigner.address, data, executable: false,
			lamports: lamports(10_000_000n), programAddress: ctx.programId, space: 48n });
	}
	return { oracle: oracleSigner.address, authority };
}

export async function multisigAccounts(ctx, initialized) {
	const members = [];
	for (let seed = 21; seed < 24; seed++) members.push(await ctx.signer(seed));
	const [config, bump] = await getProgramDerivedAddress({ programAddress: ctx.programId,
		seeds: ["multisig", encoder.encode(ctx.payer.address)] });
	const [vault] = await getProgramDerivedAddress({ programAddress: ctx.programId,
		seeds: ["vault", encoder.encode(config)] });
	const recipient = (await ctx.signer(31)).address;
	if (initialized) {
		const data = new Uint8Array(398);
		data.set(accountTag("MultisigConfig"));
		data.set(encoder.encode(ctx.payer.address), 8);
		data[40] = 2;
		data[41] = bump;
		new DataView(data.buffer).setUint16(76, members.length, true);
		for (let i = 0; i < members.length; i++) data.set(encoder.encode(members[i].address), 78 + i * 32);
		ctx.svm.setAccount({ address: config, data, executable: false,
			lamports: lamports(10_000_000n), programAddress: ctx.programId, space: 398n });
		ctx.svm.setAccount({ address: vault, data: new Uint8Array(0), executable: false,
			lamports: lamports(1_000_000_000n), programAddress: SYSTEM, space: 0n });
	}
	return { members, config, bump, vault, recipient };
}

export function multisigCheck(ctx, x) {
	const account = ctx.svm.getAccount(x.config);
	if (!account || account.data.length !== 398) throw new Error("multisig account size differs");
	const data = account.data;
	if (data[40] !== 2 || data[41] !== x.bump || new DataView(data.buffer, data.byteOffset, data.length).getUint16(76, true) !== x.members.length) throw new Error("multisig metadata differs");
	for (let i = 0; i < x.members.length; i++) {
		if (Buffer.compare(Buffer.from(data.subarray(78 + i * 32, 110 + i * 32)), Buffer.from(encoder.encode(x.members[i].address)))) throw new Error("multisig member differs");
	}
}

export const SUITES = [
	{
		name: "helloworld",
		programId: "B7ihZyoXZ1fwAY3TugkiFJ6SXkzJwMuQrxrekBaSmn32",
		cases: [{
			name: "init",
			async build(ctx) {
				const [counter] = await getProgramDerivedAddress({ programAddress: ctx.programId, seeds: ["counter"] });
				return {
					accounts: [ctx.meta(ctx.payer.address, true, true), ctx.meta(counter, false, true), ctx.meta(SYSTEM, false, false)],
					data: { anchor: anchorTag("init"), pinocchio: new Uint8Array(0) },
				};
			},
		}],
	},
	{
		name: "vault",
		programId: "33333333333333333333333333333333333333333333",
		cases: [
			{
				name: "deposit",
				async build(ctx) {
					const [vault] = await getProgramDerivedAddress({ programAddress: ctx.programId, seeds: ["vault", encoder.encode(ctx.payer.address)] });
					return {
						accounts: [ctx.meta(ctx.payer.address, true, true), ctx.meta(vault, false, true), ctx.meta(SYSTEM, false, false)],
						data: { anchor: concat(anchorTag("deposit"), u64(1_000_000)), byte: concat(byteTag(0), u64(1_000_000)) },
					};
				},
			},
			{
				name: "withdraw",
				async build(ctx) {
					const [vault] = await getProgramDerivedAddress({ programAddress: ctx.programId, seeds: ["vault", encoder.encode(ctx.payer.address)] });
					ctx.svm.setAccount({ address: vault, data: new Uint8Array(0), executable: false, lamports: lamports(1_000_000_000n), programAddress: ctx.programId, space: 0n });
					return {
						accounts: [ctx.meta(ctx.payer.address, true, true), ctx.meta(vault, false, true)],
						data: { anchor: concat(anchorTag("withdraw"), u64(1_000_000)), byte: concat(byteTag(1), u64(1_000_000)) },
					};
				},
			},
		],
	},
	{
		name: "nested",
		programId: "66666666666666666666666666666666666666666666",
		cases: [
			{
				name: "initialize",
				async build(ctx) {
					const { config, counter } = await nestedAccounts(ctx, false);
					return {
						accounts: [ctx.meta(ctx.payer.address, true, true), ctx.meta(config, false, true), ctx.meta(counter, false, true), ctx.meta(SYSTEM, false, false)],
						data: { anchor: anchorTag("initialize"), byte: byteTag(0) },
						check: () => nestedCounterCheck(ctx, config, counter, 0),
					};
				},
			},
			...[["increment", 1, 42], ["reset", 2, 0]].map(([name, tag, expected]) => ({
				name,
				async build(ctx) {
					const { config, counter } = await nestedAccounts(ctx, true);
					return {
						accounts: [ctx.meta(ctx.payer.address, true, false), ctx.meta(config, false, false), ctx.meta(counter, false, true)],
						data: { anchor: anchorTag(name), byte: byteTag(tag) },
						check: () => nestedCounterCheck(ctx, config, counter, expected),
					};
				},
			})),
		],
	},
	{
		name: "prop-amm", programId: "55555555555555555555555555555555555555555555",
		cases: [
			{ name: "update", async build(ctx) {
				const x = await oracleAccounts(ctx, true, true);
				return { accounts: [ctx.meta(x.oracle, false, true), ctx.meta(x.authority.address, true, false)],
					data: { anchor: concat(anchorTag("update"), u64(1234)), byte: concat(byteTag(0), u64(1234)) },
					check: () => { const data = ctx.svm.getAccount(x.oracle).data;
						if (new DataView(data.buffer, data.byteOffset, data.length).getBigUint64(40, true) !== 1234n) throw new Error("oracle price differs"); }, };
			} },
			{ name: "initialize", async build(ctx) {
				const x = await oracleAccounts(ctx, false);
				return { accounts: [ctx.meta(ctx.payer.address, true, true), ctx.meta(x.oracle, true, true), ctx.meta(SYSTEM, false, false)],
					data: { anchor: anchorTag("initialize"), byte: byteTag(1) },
					check: () => { const data = ctx.svm.getAccount(x.oracle).data;
						if (data.length !== 48 || Buffer.compare(Buffer.from(data.subarray(8, 40)), Buffer.from(encoder.encode(ctx.payer.address)))) throw new Error("oracle init differs"); }, };
			} },
			{ name: "rotate_authority", async build(ctx) {
				const x = await oracleAccounts(ctx, true);
				const next = new Uint8Array(32).fill(9);
				return { accounts: [ctx.meta(x.oracle, false, true), ctx.meta(x.authority.address, true, false)],
					data: { anchor: concat(anchorTag("rotate_authority"), next), byte: concat(byteTag(2), next) },
					check: () => { if (Buffer.compare(Buffer.from(ctx.svm.getAccount(x.oracle).data.subarray(8, 40)), Buffer.from(next))) throw new Error("oracle authority differs"); }, };
			} },
		],
	},
	{
		name: "multisig", programId: "44444444444444444444444444444444444444444444",
		cases: [
			{ name: "create", async build(ctx) {
				const x = await multisigAccounts(ctx, false);
				return { accounts: [ctx.meta(ctx.payer.address, true, true), ctx.meta(x.config, false, true), ctx.meta(SYSTEM, false, false), ...x.members.map(m => ctx.meta(m.address, true, false))],
					data: { anchor: concat(anchorTag("create"), byteTag(2)), byte: concat(byteTag(0), byteTag(2)) }, check: () => multisigCheck(ctx, x) };
			} },
			{ name: "deposit", async build(ctx) {
				const x = await multisigAccounts(ctx, true);
				return { accounts: [ctx.meta(ctx.payer.address, true, true), ctx.meta(x.config, false, false), ctx.meta(x.vault, false, true), ctx.meta(SYSTEM, false, false)],
					data: { anchor: concat(anchorTag("deposit"), u64(1_000_000)), byte: concat(byteTag(1), u64(1_000_000)) },
					check: () => { multisigCheck(ctx, x); if (ctx.svm.getAccount(x.vault).lamports !== 1_001_000_000n) throw new Error("vault deposit differs"); } };
			} },
			{ name: "set_label", async build(ctx) {
				const x = await multisigAccounts(ctx, true);
				const label = new Uint8Array(32); label.set(new TextEncoder().encode("multisig"));
				const payload = concat(byteTag(8), label);
				return { accounts: [ctx.meta(ctx.payer.address, true, true), ctx.meta(x.config, false, true)],
					data: { anchor: concat(anchorTag("set_label"), payload), byte: concat(byteTag(2), payload) },
					check: () => { multisigCheck(ctx, x); const data = ctx.svm.getAccount(x.config).data;
						if (new DataView(data.buffer, data.byteOffset, data.length).getUint16(42, true) !== 8 || Buffer.compare(Buffer.from(data.subarray(44, 52)), Buffer.from(label.subarray(0, 8)))) throw new Error("label differs"); } };
			} },
			{ name: "execute_transfer", async build(ctx) {
				const x = await multisigAccounts(ctx, true);
				const before = ctx.svm.getAccount(x.recipient).lamports;
				return { accounts: [ctx.meta(x.config, false, false), ctx.meta(ctx.payer.address, false, false), ctx.meta(x.vault, false, true), ctx.meta(x.recipient, false, true), ctx.meta(SYSTEM, false, false), ...x.members.slice(0, 2).map(m => ctx.meta(m.address, true, false))],
					data: { anchor: concat(anchorTag("execute_transfer"), u64(1_000_000)), byte: concat(byteTag(3), u64(1_000_000)) },
					check: () => { multisigCheck(ctx, x); if (ctx.svm.getAccount(x.recipient).lamports !== before + 1_000_000n || ctx.svm.getAccount(x.vault).lamports !== 999_000_000n) throw new Error("signed transfer differs"); } };
			} },
		],
	},
];
