import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { copyFileSync, mkdirSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import {
	AccountRole,
	address,
	appendTransactionMessageInstruction,
	createKeyPairSignerFromPrivateKeyBytes,
	createTransactionMessage,
	getAddressDecoder,
	getAddressEncoder,
	getProgramDerivedAddress,
	lamports,
	pipe,
	setTransactionMessageFeePayerSigner,
	setTransactionMessageLifetimeUsingBlockhash,
	signTransactionMessageWithSigners,
} from "@solana/kit";
import { LiteSVM } from "litesvm";
import { DATA, hibernalShapes } from "./accountTableShapes.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const argv = process.argv.slice(2);
const option = (name, fallback) => {
	const at = argv.indexOf(`--${name}`);
	return at < 0 ? fallback : argv[at + 1];
};
const msc = option("msc", "");
const form = option("form", "std");
const suite = option("suite", "matrix");
const work = resolve(option("work", "/tmp/accountTableCost"));
const localTables = argv.includes("--local-tables");
if (!msc || !["std", "table", "chain"].includes(form) || !["matrix", "decorators", "hibernal", "refusals", "escrow"].includes(suite)) {
	console.error("usage: node accountTableCost.mjs --msc <msc> [--form std|table|chain] [--suite matrix|decorators|hibernal|refusals|escrow] [--work <dir>] [--local-tables]");
	console.error("  std:   accounts<T>() as the std beside <msc> expands it (one Result per field, one try per check)");
	console.error("  table: a const table per accounts struct and one shared walker, accountTableProto.cms (built by an <msc> at this tree's root)");
	console.error("  chain: the same per-field calls returning a failure code, one failure site per struct, accountTableProto.cms");
	console.error("  --local-tables: the table form with each table declared inside its handler, the shape a macro can emit today");
	console.error("  matrix: bytes and CU per account kind; decorators: per decorator; hibernal: a program shaped like Hibernal's;");
	console.error("  escrow: examples/escrow with its three accounts structs in the form; refusals: every refusal answers the code Anchor's constraint does");
	process.exit(2);
}

const TOOLS = `${process.env.HOME}/.cache/solana/v1.57/platform-tools/llvm/bin`;
const encoder = getAddressEncoder();
const decoder = getAddressDecoder();
const SYSTEM = address("11111111111111111111111111111111");
const TOKEN = address("TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA");
const ASSOCIATED = address("ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL");
const DELEGATION = address("DELeGGvXpWV2fqJUhqcF5ZSYMS4JTLjteaAMARRSaeSh");

const sha = (text) => new Uint8Array(createHash("sha256").update(text).digest());
const addressFrom = (label) => decoder.decode(sha(label));
const bytesOf = (key) => new Uint8Array(encoder.encode(key));
const word = (bytes, at) => new DataView(bytes.buffer, bytes.byteOffset).getBigUint64(at, true);
const hexWord = (value) => `0x${BigInt.asUintN(64, value).toString(16).padStart(16, "0")}`;
const wordsOf = (key) => [0, 8, 16, 24].map((at) => word(bytesOf(key), at));
const accountDiscriminator = (name) => sha(`account:${name}`).subarray(0, 8);
const flipped = (bytes, at) => {
	const out = new Uint8Array(bytes);
	out[at] ^= 0xff;
	return out;
};

const signers = new Map();
async function signerOf(label) {
	if (!signers.has(label)) signers.set(label, await createKeyPairSignerFromPrivateKeyBytes(sha(`signer:${label}`)));
	return signers.get(label);
}
const programSigner = await signerOf("program");
const payer = await signerOf("payer");
const PROGRAM = programSigner.address;

const WK_CONST = { systemProgram: "SYSTEM_PROGRAM_ID", tokenProgram: "TOKEN_PROGRAM_ID", delegationProgram: "DELEGATION_PROGRAM_ID", associatedTokenProgram: "ASSOCIATED_TOKEN_PROGRAM_ID" };
const WELL_KNOWN = { systemProgram: SYSTEM, tokenProgram: TOKEN, delegationProgram: DELEGATION, associatedTokenProgram: ASSOCIATED };
const USER_KEYS = {
	hydraProgram: addressFrom("user:hydraProgram"),
	magicProgram: addressFrom("user:magicProgram"),
	magicVault: addressFrom("user:magicVault"),
	magicContext: addressFrom("user:magicContext"),
};
const PROGRAM_IDS = { System: SYSTEM, Token: TOKEN, AssociatedToken: ASSOCIATED };
const PROGRAM_INDEX = { System: 0n, Token: 1n, AssociatedToken: 2n };

const ALIGN = { uint8: 1, uint16: 2, uint32: 4, uint64: 8, Pubkey: 1 };
const WIDTH = { uint8: 1, uint16: 2, uint32: 4, uint64: 8, Pubkey: 32 };

function layoutOf(members) {
	let offset = 0;
	let align = 1;
	const at = {};
	for (const [name, type] of members) {
		offset = Math.ceil(offset / ALIGN[type]) * ALIGN[type];
		at[name] = { offset, type };
		offset += WIDTH[type];
		align = Math.max(align, ALIGN[type]);
	}
	return { at, size: Math.ceil(offset / align) * align };
}

const DATAS = {};
for (const [name, members] of Object.entries({ Pet: [["owner", "Pubkey"], ["points", "uint64"], ["bump", "uint8"]], ...DATA })) {
	DATAS[name] = { name, members, ...layoutOf(members) };
}

function dataSource(datas) {
	return Object.values(datas).map((d) => `export struct ${d.name} {
${d.members.map(([n, t]) => `\t${n}: ${t};`).join("\n")}
}

export function discriminator(this typeof ${d.name}): Discriminator {
	return @comptime { return accountDiscriminator("${d.name}"); };
}
`).join("\n");
}

function parseType(text) {
	const open = text.indexOf("<");
	if (open < 0) return { base: text, inner: "" };
	return { base: text.slice(0, open), inner: text.slice(open + 1, -1) };
}

const isSigner = (field) => ["Signer", "WritableSigner"].includes(parseType(field.type).base);

function refText(ref) {
	if (ref.field) return ref.field;
	if (ref.data) return `${ref.data[0]}.${ref.data[1]}`;
	if (ref.wk) return WK_CONST[ref.wk];
	if (ref.own) return "programId()";
	if (ref.user) return `Pubkey.${ref.user}()`;
	throw new Error("bad key reference");
}

function seedText(seed) {
	if (seed.text !== undefined) return JSON.stringify(seed.text);
	if (seed.key) return seed.key;
	if (seed.data) return `${seed.data[0]}.${seed.data[1]}`;
	if (seed.le) return `leBytes(${seed.le.of}.${seed.le.member}${seed.le.cast ? ` as ${seed.le.cast}` : ""})`;
	throw new Error("bad seed");
}

function decoText(d) {
	const error = d.error ? `, ${d.error}` : "";
	switch (d.d) {
		case "seeds": return `@seeds(${d.seeds.map(seedText).join(", ")}) ${d.bump ? `@bump(${d.bump})` : "@bump"}`;
		case "hasOne": return `@hasOne(${d.name}${error})`;
		case "address": return `@address(${refText(d.key)}${error})`;
		case "associated": return `@associated(${d.mint}, ${d.authority})`;
		case "tokenMint": return `@tokenMint(${refText(d.key)})`;
		case "tokenAuthority": return `@tokenAuthority(${refText(d.key)})`;
		case "constraint": return `@constraint(${d.std}${error})`;
		default: throw new Error(`bad decorator ${d.d}`);
	}
}

function structSource(shape) {
	const lines = shape.fields.map((f) => {
		const decos = (f.decos ?? []).map(decoText);
		return `\t${decos.length ? `${decos.join(" ")} ` : ""}${f.name}: ${f.type};`;
	});
	return `export struct ${shape.name} {\n${lines.join("\n")}\n}\n`;
}

const EXTRA = { systemOwned: 1n, programKey: 2n, programData: 3n, delegatedData: 4n, mintVerify: 5n, tokenVerify: 6n };
const NEED = { signer: 0x100n, writable: 0x10000n, executable: 0x1000000n, claim: 0x10n };
const OP = { end: 0n, equal: 1n, associated: 2n, seeds: 3n };
const FROM = { account: 1n, table: 2n, program: 3n, external: 4n };
const CUSTOM = 0x4000000000000000n;
const CODES = { hasOne: 2001n, address: 2012n, tokenMint: 2014n, tokenAuthority: 2015n };

function fieldWords(field, datas) {
	const t = parseType(field.type);
	const make = (extra, need, size = 0n) => extra | need | (size << 32n);
	const data = (extra, need) => ({ words: [make(extra, need)], data: t.inner });
	switch (t.base) {
		case "Signer": return { words: [make(0n, NEED.signer)] };
		case "WritableSigner": return { words: [make(0n, NEED.signer | NEED.writable)] };
		case "Writable": return { words: [make(0n, NEED.writable)] };
		case "SystemAccount": return { words: [make(EXTRA.systemOwned, 0n)] };
		case "Account": return { words: [0n] };
		case "Program": return { words: [make(EXTRA.programKey, NEED.executable, PROGRAM_INDEX[t.inner])] };
		case "Owned": return data(EXTRA.programData, 0n);
		case "Mutable": return data(EXTRA.programData, NEED.writable | NEED.claim);
		case "Delegated": return data(EXTRA.delegatedData, 0n);
		case "External": return { words: [make(t.inner === "Mint" ? EXTRA.mintVerify : EXTRA.tokenVerify, 0n)] };
		case "ExternalMutable": return { words: [make(t.inner === "Mint" ? EXTRA.mintVerify : EXTRA.tokenVerify, NEED.writable | NEED.claim)] };
		default: throw new Error(`no table kind for ${field.type}`);
	}
}

function tableOf(shape, datas) {
	const index = new Map(shape.fields.map((f, i) => [f.name, i]));
	const at = (name) => {
		if (!index.has(name)) throw new Error(`${shape.name} has no field ${name}`);
		return index.get(name);
	};
	const fields = [];
	const operands = [];
	for (const f of shape.fields) {
		const encoded = fieldWords(f, datas);
		fields.push(...encoded.words);
		if (encoded.data) operands.push({ index: fields.length - encoded.words.length, expr: [`@comptime { return word(${encoded.data}.discriminator()); }`, `sizeof(${encoded.data}) as uint64`] });
	}
	const ext = [];
	const prelude = [];
	const slots = [];
	const fallbacks = [];
	const external = (expr) => {
		ext.push(expr);
		return ext.length - 1;
	};
	const slotOf = (error) => {
		if (!error) return 0n;
		slots.push(error);
		return BigInt(slots.length);
	};
	const account = (name, words = 1) => ({ t: "account", i: at(name), o: words });
	const reference = (ref) => {
		if (ref.field) return account(ref.field);
		if (ref.own) return { t: "own" };
		if (ref.wk) return { t: "const", key: WELL_KNOWN[ref.wk] };
		if (ref.user) {
			const name = `$k${prelude.length}`;
			prelude.push(`const ${name} = Pubkey.${ref.user}();`);
			return { t: "ext", i: external(`bytesAddress(${name}.bytes)`) };
		}
		if (ref.data) return { t: "ext", i: external(`bytesAddress($accounts.${ref.data[0]}.data().${ref.data[1]}.bytes)`) };
		throw new Error("bad key reference");
	};
	const items = [];
	for (const f of shape.fields) {
		const decos = f.decos ?? [];
		const self = account(f.name);
		const seeded = decos.find((d) => d.d === "seeds");
		if (seeded) {
			const elements = seeded.seeds.map((seed) => {
				if (seed.text !== undefined) return { text: new TextEncoder().encode(seed.text) };
				if (seed.key) return { address: account(seed.key) };
				if (seed.data) return { address: reference({ data: seed.data }) };
				return { integer: external(`$accounts.${seed.le.of}.data().${seed.le.member} as uint64`), width: seed.le.width };
			});
			const bump = seeded.bump ? external(`$accounts.${seeded.bump.split(".")[0]}.data().${seeded.bump.split(".")[1]} as uint64`) : null;
			items.push({ seeds: true, field: at(f.name), elements, bump });
		}
		for (const d of decos.filter((x) => x.d === "associated")) {
			items.push({ associated: true, token: self, wallet: account(d.authority), mint: account(d.mint) });
		}
		for (const d of decos.filter((x) => x.d === "hasOne")) {
			const stored = { t: "ext", i: external(`bytesAddress($accounts.${f.name}.data().${d.name}.bytes)`) };
			items.push({ equal: true, left: stored, right: account(d.name), slot: slotOf(d.error), code: CODES.hasOne });
		}
		for (const d of decos.filter((x) => x.d === "constraint")) fallbacks.push({ expr: d.table, error: d.error });
		for (const d of decos.filter((x) => x.d === "address")) {
			items.push({ equal: true, left: self, right: reference(d.key), slot: slotOf(d.error), code: CODES.address });
		}
		for (const d of decos.filter((x) => x.d === "tokenAuthority")) {
			items.push({ equal: true, left: account(f.name, 15), right: reference(d.key), slot: 0n, code: CODES.tokenAuthority });
		}
		for (const d of decos.filter((x) => x.d === "tokenMint")) {
			items.push({ equal: true, left: account(f.name, 11), right: reference(d.key), slot: 0n, code: CODES.tokenMint });
		}
	}
	if (items.length === 0) return { fields, constraints: null, operands, ext, prelude, slots, fallbacks };
	let length = 1;
	for (const item of items) {
		if (item.equal || item.associated) length += 2;
		else {
			length += 1;
			for (const e of item.elements) length += e.text ? 1 + Math.ceil(e.text.length / 8) : 1;
		}
	}
	const constants = [];
	const constantAt = (key) => {
		const found = constants.findIndex((c) => c.key === key);
		if (found >= 0) return found;
		constants.push({ key });
		return constants.length - 1;
	};
	const encode = (s) => {
		if (s.t === "account") return FROM.account | (BigInt(s.i) << 4n) | (BigInt(s.o) << 12n);
		if (s.t === "own") return FROM.program;
		if (s.t === "ext") return FROM.external | (BigInt(s.i) << 4n);
		const place = length + 4 * constantAt(s.key);
		if (place >= 256) throw new Error(`${shape.name}: the constraint table is too long for an 8-bit word offset`);
		return FROM.table | (BigInt(place) << 12n);
	};
	const stream = [];
	for (const item of items) {
		if (item.equal) {
			stream.push(OP.equal | (encode(item.left) << 8n) | (encode(item.right) << 28n) | (item.slot << 48n), item.code);
		} else if (item.associated) {
			stream.push(OP.associated | (encode(item.token) << 8n) | (encode(item.wallet) << 28n), encode(item.mint));
		} else {
			const count = item.elements.length;
			stream.push(OP.seeds | (BigInt(item.field) << 8n) | (BigInt(count) << 16n) | ((item.bump === null ? 0n : 1n) << 24n) | (BigInt(item.bump ?? 0) << 32n));
			for (const e of item.elements) {
				if (e.text) {
					const padded = new Uint8Array(Math.ceil(e.text.length / 8) * 8);
					padded.set(e.text);
					stream.push(1n | (BigInt(e.text.length) << 8n));
					for (let i = 0; i < padded.length; i += 8) stream.push(word(padded, i));
				} else if (e.address) stream.push(2n | (encode(e.address) << 8n));
				else stream.push(3n | (BigInt(e.integer) << 12n) | (BigInt(e.width) << 28n));
			}
		}
	}
	stream.push(OP.end);
	if (stream.length !== length) throw new Error(`${shape.name}: constraint stream ${stream.length} words, expected ${length}`);
	for (const c of constants) stream.push(...wordsOf(c.key));
	return { fields, constraints: stream, operands, ext, prelude, slots, fallbacks };
}

const sumOf = (shape, holder) => shape.fields.map((f) => `(${holder}.${f.name} as Account).address`).join(" + ");

function handlerSource(shape, datas) {
	if (form === "std") {
		return `function ${shape.handler}(): Result<uint64, ProgramError> {
	const x = try accounts<${shape.name}>();
	return Result.ok(${sumOf(shape, "x")});
}
`;
	}
	const parts = statementsOf(shape, datas);
	return `${parts.consts}function ${shape.handler}(): Result<uint64, ProgramError> {
${parts.body}	return Result.ok(${sumOf(shape, "$accounts")});
}
`;
}

function statementsOf(shape, datas) {
	if (form === "chain") return { consts: "", body: chainBody(shape) };
	const t = tableOf(shape, datas);
	let consts = `const ${shape.name}Fields: uint64[${t.fields.length}] = [${t.fields.map(hexWord).join(", ")}];\n`;
	if (t.constraints) consts += `const ${shape.name}Constraints: uint64[${t.constraints.length}] = [${t.constraints.map(hexWord).join(", ")}];\n`;
	let text = "";
	if (localTables) {
		text = consts.split("\n").filter((line) => line !== "").map((line) => `\t${line}\n`).join("");
		consts = "";
	}
	text += `\tlet $found: Account[${shape.fields.length}];\n`;
	if (t.operands.length) {
		text += `\tlet $ops: uint64[${2 * shape.fields.length}];\n`;
		for (const o of t.operands) text += `\t$ops[${2 * o.index}] = ${o.expr[0]};\n\t$ops[${2 * o.index + 1}] = ${o.expr[1]};\n`;
	}
	text += `\tconst $typed = verifiedAccounts(${shape.name}Fields, ${t.operands.length ? "$ops" : "[]"}, $found);
	if ($typed != 0) { try failed($typed); }
	const $accounts: ${shape.name} = { ${shape.fields.map((f, i) => `${f.name}: $found[${i}] as ${f.type}`).join(", ")} };
`;
	if (t.constraints) {
		for (const line of t.prelude) text += `\t${line}\n`;
		text += `\tconst $ext: uint64[${Math.max(t.ext.length, 1)}] = [${t.ext.length ? t.ext.join(", ") : "0"}];
	const $verdict = verifiedConstraints(${shape.name}Constraints, $ext, $found);
`;
		if (t.slots.length) {
			text += "\tif ($verdict != 0) {\n";
			t.slots.forEach((error, i) => {
				text += `\t\tif ($verdict == ${hexWord(CUSTOM | BigInt(i))}) { try raise(${error}); }\n`;
			});
			text += "\t\ttry failed($verdict);\n\t}\n";
		} else text += "\tif ($verdict != 0) { try failed($verdict); }\n";
	}
	for (const fb of t.fallbacks) text += `\tif (!(${fb.expr})) { try raise(${fb.error ?? "ProgramError.constraintRaw()"}); }\n`;
	return { consts, body: text };
}

function chainBody(shape) {
	let text = "\tlet $c: uint64 = 0;\n";
	shape.fields.forEach((f, i) => {
		const t = parseType(f.type);
		const out = `$a${i}`;
		let call;
		switch (t.base) {
			case "Signer": call = `signerCode(${i}, ${out})`; break;
			case "WritableSigner": call = `writableSignerCode(${i}, ${out})`; break;
			case "Writable": call = `writableCode(${i}, ${out})`; break;
			case "SystemAccount": call = `systemCode(${i}, ${out})`; break;
			case "Account": call = `anyCode(${i}, ${out})`; break;
			case "Program": call = `programCode(${i}, ${PROGRAM_INDEX[t.inner]}, ${out})`; break;
			case "Owned": call = `ownedCode(${i}, @comptime { return word(${t.inner}.discriminator()); }, sizeof(${t.inner}) as uint64, ${out})`; break;
			case "Mutable": call = `mutableCode(${i}, @comptime { return word(${t.inner}.discriminator()); }, sizeof(${t.inner}) as uint64, ${out})`; break;
			case "Delegated": call = `delegatedCode(${i}, @comptime { return word(${t.inner}.discriminator()); }, sizeof(${t.inner}) as uint64, ${out})`; break;
			default: call = null;
		}
		if (call) {
			text += `\tlet ${out}: Account;\n\tif ($c == 0) { $c = ${call}; }\n`;
		} else {
			const verified = `${t.inner}.verify(${i})`;
			const expr = t.base === "ExternalMutable" ? `exclusiveWritable(try ${verified})` : verified;
			text += `\tlet ${out}: Account;\n\tif ($c == 0) {\n\t\tconst $r${i} = ${expr};\n\t\tif ($r${i}.ok) { ${out} = $r${i}.value; } else { $c = $r${i}.error.code; }\n\t}\n`;
		}
	});
	text += `\tif ($c != 0) { try failed($c); }\n`;
	text += `\tconst $accounts: ${shape.name} = { ${shape.fields.map((f, i) => `${f.name}: $a${i} as ${f.type}`).join(", ")} };\n`;
	text += chainConstraints(shape);
	return text;
}

function keyExpr(ref) {
	if (ref.field) return `$accounts.${ref.field}.keyAddress()`;
	if (ref.data) return `bytesAddress($accounts.${ref.data[0]}.data().${ref.data[1]}.bytes)`;
	if (ref.wk) return `bytesAddress(${WK_CONST[ref.wk]}.bytes)`;
	if (ref.own) return "bytesAddress(programId().bytes)";
	if (ref.user) return `bytesAddress(Pubkey.${ref.user}().bytes)`;
	throw new Error("bad key reference");
}

function chainConstraints(shape) {
	let text = "";
	const SENTINEL = "0x7fffffffffffffff";
	const step = (call, error) => {
		if (!error) return `\tif ($c == 0) { $c = ${call(null)}; }\n`;
		return `\tif ($c == 0) {\n\t\t$c = ${call(SENTINEL)};\n\t\tif ($c == ${SENTINEL}) { $c = (${error}).code; }\n\t}\n`;
	};
	let any = false;
	for (const f of shape.fields) {
		const self = `$accounts.${f.name}.keyAddress()`;
		const decos = f.decos ?? [];
		const seeded = decos.find((d) => d.d === "seeds");
		if (seeded) {
			any = true;
			const elements = seeded.seeds.map((seed) => {
				if (seed.text !== undefined) return `seedText(${JSON.stringify(seed.text)})`;
				if (seed.key) return `seedKey($accounts.${seed.key}.keyAddress())`;
				if (seed.data) return `seedBytes($accounts.${seed.data[0]}.data().${seed.data[1]}.bytes)`;
				return `seedBytes(leBytes($accounts.${seed.le.of}.data().${seed.le.member}${seed.le.cast ? ` as ${seed.le.cast}` : ""}))`;
			}).join(", ");
			if (seeded.bump) {
				const [owner, member] = seeded.bump.split(".");
				text += `\tif ($c == 0) { $c = seedsGivenCode(${self}, [${elements}], $accounts.${owner}.data().${member}); }\n`;
			} else text += `\tif ($c == 0) { $c = seedsCanonicalCode(${self}, [${elements}]); }\n`;
		}
		for (const d of decos.filter((x) => x.d === "associated")) {
			any = true;
			text += `\tif ($c == 0) { $c = associatedCode(${self}, $accounts.${d.authority}.keyAddress(), $accounts.${d.mint}.keyAddress()); }\n`;
		}
		for (const d of decos.filter((x) => x.d === "hasOne")) {
			any = true;
			text += step((failure) => `keysCode(bytesAddress($accounts.${f.name}.data().${d.name}.bytes), $accounts.${d.name}.keyAddress(), ${failure ?? 2001})`, d.error);
		}
		for (const d of decos.filter((x) => x.d === "constraint")) {
			any = true;
			text += `\tif ($c == 0 && !(${d.table})) { $c = ${d.error ? `(${d.error}).code` : 2003}; }\n`;
		}
		for (const d of decos.filter((x) => x.d === "address")) {
			any = true;
			text += step((failure) => `keysCode(${self}, ${keyExpr(d.key)}, ${failure ?? 2012})`, d.error);
		}
		for (const d of decos.filter((x) => x.d === "tokenAuthority")) {
			any = true;
			text += `\tif ($c == 0) { $c = tokenAuthorityCode(${self}, ${keyExpr(d.key)}); }\n`;
		}
		for (const d of decos.filter((x) => x.d === "tokenMint")) {
			any = true;
			text += `\tif ($c == 0) { $c = tokenMintCode(${self}, ${keyExpr(d.key)}); }\n`;
		}
	}
	if (any) text += `\tif ($c != 0) { try failed($c); }\n`;
	return text;
}

function programSource(shapes, datas, extra = "") {
	const userKeys = Object.entries(USER_KEYS).map(([name, key]) => `export function ${name}(this typeof Pubkey): Pubkey {
	return @comptime { return pubkeyOf("${key}"); };
}
`).join("\n");
	const imports = `import {
	Account,
	AssociatedToken,
	Delegated,
	Discriminator,
	External,
	ExternalMutable,
	Mutable,
	Owned,
	Program,
	ProgramError,
	Pubkey,
	Signer,
	System,
	SystemAccount,
	Token,
	Writable,
	WritableSigner,
	ASSOCIATED_TOKEN_PROGRAM_ID,
	DELEGATION_PROGRAM_ID,
	SYSTEM_PROGRAM_ID,
	TOKEN_PROGRAM_ID,
	account,
	accountDiscriminator,
	accounts,
	address,
	argU8,
	associated,
	bump,
	constraint,
	failWith,
	hasOne,
	leBytes,
	programId,
	pubkeyOf,
	seeds,
	tokenAuthority,
	tokenMint,
	word,
} from "std/solana";
import { Mint, TokenAccount } from "std/solana/token";
${form === "chain" ? 'import { exclusiveWritable } from "std/solana";\nimport { bytesAddress, seedBytes, seedKey, seedText } from "std/solana/seed";\nimport { anyCode, associatedCode, delegatedCode, failed, keysCode, mutableCode, ownedCode, programCode, seedsCanonicalCode, seedsGivenCode, signerCode, systemCode, tokenAuthorityCode, tokenMintCode, writableCode, writableSignerCode } from "./accountTableProto";\n' : ""}${form === "table" ? 'import { bytesAddress } from "std/solana/seed";\nimport { failed, verifiedAccounts, verifiedConstraints } from "./accountTableProto";\n' : ""}`;
	const body = shapes.map((s) => `${structSource(s)}${handlerSource(s, datas)}`).join("\n");
	const dispatch = shapes.map((s) => `\tif (op == ${s.op}) { result = ${s.handler}(); }`).join("\n");
	return `${imports}
${dataSource(datas)}
${userKeys}
${extra}
function raise(error: ProgramError): Result<void, ProgramError> {
	return Result.err(error);
}

function idle(): Result<uint64, ProgramError> {
	const first = try account(0);
	return Result.ok(first.address);
}

${body}
function entry(): void {
	const op = argU8(0);
	let result = idle();
${dispatch}
	if (!result.ok) { failWith(result.error); }
}
entry();
`;
}

function build(name, source) {
	const dir = join(work, form, name);
	rmSync(dir, { recursive: true, force: true });
	mkdirSync(dir, { recursive: true });
	writeFileSync(join(dir, "program.ms"), source);
	if (form !== "std") copyFileSync(join(HERE, "accountTableProto.cms"), join(dir, "accountTableProto.cms"));
	const out = join(dir, "program.so");
	try {
		execFileSync(msc, ["build", join(dir, "program.ms"), "--os=solana", `--output=${out}`], { cwd: dir, stdio: ["ignore", "pipe", "pipe"], maxBuffer: 1 << 28 });
	} catch (error) {
		const text = `${error.stdout ?? ""}${error.stderr ?? ""}`;
		throw new Error(`${name} did not build:\n${text.split("\n").filter((l) => /error/.test(l)).slice(0, 12).join("\n")}`);
	}
	return { path: out, sizes: sizesOf(out) };
}

function sizesOf(path) {
	const table = execFileSync(`${TOOLS}/llvm-readelf`, ["-S", "-W", path]).toString();
	const section = (name) => {
		const hit = new RegExp(`\\s${name.replace(".", "\\.")}\\s+\\w+\\s+\\w+\\s+\\w+\\s+(\\w+)`).exec(table);
		return hit ? parseInt(hit[1], 16) : 0;
	};
	return { so: statSync(path).size, text: section(".text"), rodata: section(".rodata") };
}

class Scenario {
	constructor(shape, datas) {
		this.shape = shape;
		this.datas = datas;
		this.fields = new Map(shape.fields.map((f) => [f.name, f]));
		this.keys = new Map();
		this.values = new Map();
		this.bumps = new Map();
		this.stack = [];
		this.named = new Set();
		for (const f of shape.fields) {
			for (const d of f.decos ?? []) {
				if (d.d === "hasOne") this.named.add(`${f.name}.${d.name}`);
				if (d.d === "seeds") {
					for (const seed of d.seeds) {
						if (seed.data) this.named.add(`${seed.data[0]}.${seed.data[1]}`);
						if (seed.le) this.named.add(`${seed.le.of}.${seed.le.member}`);
					}
				}
				if (d.key && d.key.data) this.named.add(`${d.key.data[0]}.${d.key.data[1]}`);
				if (d.claims) this.named.add(`${d.claims.owner}.${d.claims.member}`);
			}
		}
	}

	label(name) {
		return `${this.shape.name}:${name}`;
	}

	claim(owner, member) {
		for (const f of this.shape.fields) {
			if (!isSigner(f)) continue;
			for (const d of f.decos ?? []) {
				if (d.key && d.key.data && d.key.data[0] === owner && d.key.data[1] === member) return f.name;
				if (d.claims && d.claims.owner === owner && d.claims.member === member) return d.claims.by;
			}
		}
		return null;
	}

	async value(owner, member) {
		const id = `${owner}.${member}`;
		if (this.values.has(id)) return this.values.get(id);
		const field = this.fields.get(owner);
		const type = this.datas[parseType(field.type).inner].at[member].type;
		let value;
		const related = (field.decos ?? []).find((d) => d.d === "hasOne" && d.name === member);
		const claimed = this.claim(owner, member);
		if (related) value = bytesOf(await this.key(member));
		else if (claimed) value = bytesOf(await this.key(claimed));
		else if (type === "Pubkey") value = bytesOf(addressFrom(`${this.label(owner)}.${member}`));
		else value = BigInt(member === "id" ? 7 : member === "nonce" ? 3 : 1);
		this.values.set(id, value);
		return value;
	}

	async seedBytes(seed) {
		if (seed.text !== undefined) return new TextEncoder().encode(seed.text);
		if (seed.key) return bytesOf(await this.key(seed.key));
		if (seed.data) return await this.value(seed.data[0], seed.data[1]);
		const out = new Uint8Array(8);
		new DataView(out.buffer).setBigUint64(0, BigInt(await this.value(seed.le.of, seed.le.member)), true);
		return out.subarray(0, seed.le.width);
	}

	async key(name) {
		if (this.keys.has(name)) return this.keys.get(name);
		if (this.stack.includes(name)) throw new Error(`${this.shape.name}: the key of ${name} depends on itself`);
		this.stack.push(name);
		const field = this.fields.get(name);
		const t = parseType(field.type);
		const decos = field.decos ?? [];
		const seeded = decos.find((d) => d.d === "seeds");
		const assoc = decos.find((d) => d.d === "associated");
		const addressed = decos.find((d) => d.d === "address");
		let key;
		if (seeded) {
			const seeds = [];
			for (const seed of seeded.seeds) seeds.push(await this.seedBytes(seed));
			const [found, bump] = await getProgramDerivedAddress({ programAddress: PROGRAM, seeds });
			key = found;
			this.bumps.set(name, bump);
		} else if (assoc) {
			const [found] = await getProgramDerivedAddress({
				programAddress: ASSOCIATED,
				seeds: [bytesOf(await this.key(assoc.authority)), bytesOf(TOKEN), bytesOf(await this.key(assoc.mint))],
			});
			key = found;
		} else if (isSigner(field)) key = (await signerOf(this.label(name))).address;
		else if (t.base === "Program") key = PROGRAM_IDS[t.inner];
		else if (addressed) key = await this.keyOf(addressed.key);
		else if (name === "systemProgram") key = SYSTEM;
		else if (name === "tokenProgram") key = TOKEN;
		else key = addressFrom(this.label(name));
		this.stack.pop();
		this.keys.set(name, key);
		return key;
	}

	async keyOf(ref) {
		if (ref.field) return this.key(ref.field);
		if (ref.data) return decoder.decode(await this.value(ref.data[0], ref.data[1]));
		if (ref.wk) return WELL_KNOWN[ref.wk];
		if (ref.user) return USER_KEYS[ref.user];
		if (ref.own) return PROGRAM;
		throw new Error("bad key reference");
	}

	async account(field) {
		const t = parseType(field.type);
		const key = await this.key(field.name);
		const base = { key, role: AccountRole.READONLY, owner: SYSTEM, data: new Uint8Array(0), lamports: 10_000_000n };
		const decos = field.decos ?? [];
		switch (t.base) {
			case "Signer": return { ...base, role: AccountRole.READONLY_SIGNER, signer: await signerOf(this.label(field.name)) };
			case "WritableSigner": return { ...base, role: AccountRole.WRITABLE_SIGNER, signer: await signerOf(this.label(field.name)) };
			case "Writable": return { ...base, role: AccountRole.WRITABLE };
			case "SystemAccount":
			case "Account":
			case "Program": return base;
			case "Owned":
			case "Mutable":
			case "Delegated": {
				const type = this.datas[t.inner];
				const bytes = new Uint8Array(8 + type.size);
				bytes.set(accountDiscriminator(t.inner));
				const view = new DataView(bytes.buffer);
				for (const [member, info] of Object.entries(type.at)) {
					if (!this.named.has(`${field.name}.${member}`)) continue;
					const value = await this.value(field.name, member);
					const place = 8 + info.offset;
					if (info.type === "Pubkey") bytes.set(value, place);
					else if (info.type === "uint8") bytes[place] = Number(value);
					else if (info.type === "uint32") view.setUint32(place, Number(value), true);
					else view.setBigUint64(place, BigInt(value), true);
				}
				if (type.at.bump && decos.some((d) => d.d === "seeds")) bytes[8 + type.at.bump.offset] = this.bumps.get(field.name);
				return { ...base, role: t.base === "Mutable" ? AccountRole.WRITABLE : AccountRole.READONLY, owner: t.base === "Delegated" ? DELEGATION : PROGRAM, data: bytes };
			}
			case "External":
			case "ExternalMutable": {
				const role = t.base === "ExternalMutable" ? AccountRole.WRITABLE : AccountRole.READONLY;
				if (t.inner === "Mint") {
					const bytes = new Uint8Array(82);
					bytes[44] = 6;
					bytes[45] = 1;
					return { ...base, role, owner: TOKEN, data: bytes };
				}
				const bytes = new Uint8Array(165);
				bytes[108] = 1;
				for (const d of decos) {
					if (d.d === "associated") {
						bytes.set(bytesOf(await this.key(d.mint)), 0);
						bytes.set(bytesOf(await this.key(d.authority)), 32);
					}
					if (d.d === "tokenMint") bytes.set(bytesOf(await this.keyOf(d.key)), 0);
					if (d.d === "tokenAuthority") bytes.set(bytesOf(await this.keyOf(d.key)), 32);
				}
				return { ...base, role, owner: TOKEN, data: bytes };
			}
			default: throw new Error(`no account for ${field.type}`);
		}
	}
}

async function runOp(path, shape, datas, op, mutate, drop = 0) {
	const svm = new LiteSVM();
	svm.addProgramFromFile(PROGRAM, path);
	svm.airdrop(payer.address, lamports(10_000_000_000n));
	const scenario = new Scenario(shape, datas);
	const accounts = [];
	for (const field of shape.fields) {
		let spec = await scenario.account(field);
		if (mutate) spec = mutate(spec, field) ?? spec;
		accounts.push(spec);
	}
	if (drop > 0) accounts.length -= drop;
	for (const spec of accounts) {
		if ([SYSTEM, TOKEN, ASSOCIATED, PROGRAM].includes(spec.key)) continue;
		svm.setAccount({ address: spec.key, data: spec.data, executable: false, lamports: lamports(spec.lamports), programAddress: spec.owner, space: BigInt(spec.data.length) });
	}
	const data = new Uint8Array(9);
	data[8] = op;
	const message = pipe(
		createTransactionMessage({ version: 0 }),
		(m) => setTransactionMessageFeePayerSigner(payer, m),
		(m) => setTransactionMessageLifetimeUsingBlockhash({ blockhash: svm.latestBlockhash(), lastValidBlockHeight: 1000n }, m),
		(m) => appendTransactionMessageInstruction({
			programAddress: PROGRAM,
			accounts: accounts.map((a) => ({ address: a.key, role: a.role, ...(a.signer ? { signer: a.signer } : {}) })),
			data,
		}, m),
	);
	const result = svm.sendTransaction(await signTransactionMessageWithSigners(message));
	const failed = result.constructor.name === "FailedTransactionMetadata";
	const meta = failed ? result.meta() : result;
	const text = failed ? `${result.err().toString()} ${(result.meta().logs?.() ?? []).slice(-3).join(' | ')}` : "";
	return { ok: !failed, error: text, code: /InstructionErrorCustom \{ code: (\d+) \}/.exec(text)?.[1] ?? text, units: Number(meta.computeUnitsConsumed()) };
}

const pad = (value, width) => String(value).padStart(width);
const IDLE = { name: "Idle", fields: [{ name: "f0", type: "Account" }] };

const MATRIX_KINDS = [
	"Signer",
	"WritableSigner",
	"Writable",
	"SystemAccount",
	"Account",
	"Program<System>",
	"Owned<Pet>",
	"Mutable<Pet>",
	"Delegated<Pet>",
	"External<Mint>",
	"External<TokenAccount>",
	"ExternalMutable<TokenAccount>",
];
const COUNTS = [1, 8];

async function matrix() {
	const shapes = [];
	let op = 1;
	for (const type of MATRIX_KINDS) {
		for (const n of COUNTS) {
			shapes.push({ name: `M${op}`, handler: `h${op}`, op, label: type, count: n, fields: Array.from({ length: n }, (_, i) => ({ name: `f${i}`, type })) });
			op++;
		}
	}
	const all = build("matrix", programSource(shapes, DATAS));
	const idle = await runOp(all.path, IDLE, DATAS, 0);
	const crowd = await runOp(all.path, { name: "Idle8", fields: Array.from({ length: 8 }, (_, i) => ({ name: `f${i}`, type: "Account" })) }, DATAS, 0);
	console.log(`[${form}] idle ${idle.units} CU, ${((crowd.units - idle.units) / 7).toFixed(1)} CU more for each account the instruction lists and the program does not read (the runtime's input parse); the whole matrix .so ${all.sizes.so}, .text ${all.sizes.text}, .rodata ${all.sizes.rodata}`);
	const costs = new Map();
	for (const shape of shapes) {
		const outcome = await runOp(all.path, shape, DATAS, shape.op);
		if (!outcome.ok) throw new Error(`${shape.label} x${shape.count}: ${outcome.error}`);
		costs.set(`${shape.label}/${shape.count}`, outcome.units);
	}
	console.log(`${"kind".padEnd(32)}${pad("text/field", 12)}${pad("rodata/field", 14)}${pad("CU/field", 10)}${pad("CU 1 field", 12)}${pad(".so 1", 8)}${pad(".so 8", 8)}`);
	for (const type of MATRIX_KINDS) {
		const one = shapes.find((s) => s.label === type && s.count === COUNTS[0]);
		const many = shapes.find((s) => s.label === type && s.count === COUNTS[1]);
		const small = build(`bytes-${one.op}`, programSource([one], DATAS));
		const large = build(`bytes-${many.op}`, programSource([many], DATAS));
		const span = COUNTS[1] - COUNTS[0];
		const cu1 = costs.get(`${type}/${COUNTS[0]}`);
		const cuN = costs.get(`${type}/${COUNTS[1]}`);
		console.log(`${type.padEnd(32)}${pad(((large.sizes.text - small.sizes.text) / span).toFixed(1), 12)}${pad(((large.sizes.rodata - small.sizes.rodata) / span).toFixed(1), 14)}${pad(((cuN - cu1) / span).toFixed(1), 10)}${pad(cu1 - idle.units, 12)}${pad(small.sizes.so, 8)}${pad(large.sizes.so, 8)}`);
	}
}

function decoratorShapes() {
	const base = () => [
		{ name: "owner", type: "WritableSigner" },
		{ name: "mint", type: "External<Mint>" },
		{ name: "token", type: "ExternalMutable<TokenAccount>" },
		{ name: "pet", type: "Mutable<Pet>" },
		{ name: "target", type: "Writable" },
		{ name: "program", type: "Account" },
	];
	const custom = "ProgramError.invalidArgument()";
	const on = (fieldName, ...decos) => base().map((f) => (f.name === fieldName ? { ...f, decos } : f));
	const list = [
		["none", on("pet")],
		["@hasOne(owner)", on("pet", { d: "hasOne", name: "owner" })],
		["@hasOne(owner, error)", on("pet", { d: "hasOne", name: "owner", error: custom })],
		["@address(const)", on("program", { d: "address", key: { wk: "systemProgram" } })],
		["@address(sibling)", on("target", { d: "address", key: { field: "owner" } })],
		["@address(const, error)", on("program", { d: "address", key: { wk: "systemProgram" }, error: custom })],
		["@seeds @bump(stored)", on("pet", { d: "seeds", seeds: [{ text: "pet" }, { key: "owner" }], bump: "pet.bump" })],
		["@seeds @bump", on("pet", { d: "seeds", seeds: [{ text: "pet" }, { key: "owner" }], bump: null })],
		["@associated", on("token", { d: "associated", mint: "mint", authority: "owner" })],
		["@tokenMint", on("token", { d: "tokenMint", key: { field: "mint" } })],
		["@tokenAuthority", on("token", { d: "tokenAuthority", key: { field: "owner" } })],
		["@constraint", on("pet", { d: "constraint", std: "pet.points == 0", table: "$accounts.pet.data().points == 0" })],
	];
	return list.map(([label, fields], i) => ({ name: `D${i}`, label, fields, handler: `h${i}`, op: i + 1 }));
}

async function decorators() {
	const shapes = decoratorShapes();
	const all = build("decorators", programSource(shapes, DATAS));
	const idle = await runOp(all.path, IDLE, DATAS, 0);
	const results = [];
	for (const shape of shapes) {
		const outcome = await runOp(all.path, shape, DATAS, shape.op);
		if (!outcome.ok) throw new Error(`${shape.label}: ${outcome.error}`);
		results.push({ shape, units: outcome.units, sizes: build(`deco-${shape.op}`, programSource([shape], DATAS)).sizes });
	}
	const none = results[0];
	console.log(`[${form}] ${"decorator".padEnd(26)}${pad("+CU", 8)}${pad("+text", 8)}${pad("+rodata", 9)}${pad("+.so", 8)}   (six fields, no decorator: ${none.units - idle.units} CU over idle ${idle.units}, .so ${none.sizes.so}, .text ${none.sizes.text}, .rodata ${none.sizes.rodata})`);
	for (const r of results.slice(1)) {
		console.log(`${" ".repeat(form.length + 3)}${r.shape.label.padEnd(26)}${pad(r.units - none.units, 8)}${pad(r.sizes.text - none.sizes.text, 8)}${pad(r.sizes.rodata - none.sizes.rodata, 9)}${pad(r.sizes.so - none.sizes.so, 8)}`);
	}
}

async function refusals() {
	const shapes = decoratorShapes();
	const all = build("refusals", programSource(shapes, DATAS, ""));
	const by = (label) => shapes.find((s) => s.label === label);
	let failures = 0;
	const expectCode = async (what, shape, mutate, expected, drop = 0) => {
		const outcome = await runOp(all.path, shape, DATAS, shape.op, mutate, drop);
		const good = !outcome.ok && (typeof expected === "string" ? outcome.error.includes(expected) : outcome.code === String(expected));
		console.log(`${what}: ${outcome.ok ? "accepted" : outcome.code}, expected ${expected}: ${good ? "ok" : "FAILED"}`);
		if (!good) failures++;
	};
	const only = (name, change) => (spec, field) => (field.name === name ? change(spec) : undefined);
	const patch = (at, mask = 1) => (spec) => {
		const data = new Uint8Array(spec.data);
		data[at] ^= mask;
		return { ...spec, data };
	};
	const base = by("none");
	await expectCode("signer: the owner account does not sign", base, only("owner", (s) => ({ ...s, role: AccountRole.WRITABLE, signer: undefined })), 3010);
	await expectCode("the instruction lists one account fewer than the struct reads", base, undefined, 3005, 1);
	await expectCode("a field that fails comes before the missing account: the first fails first", base, only("owner", (s) => ({ ...s, role: AccountRole.WRITABLE, signer: undefined })), 3010, 1);
	await expectCode("writable signer: read-only", base, only("owner", (s) => ({ ...s, role: AccountRole.READONLY_SIGNER })), 2000);
	await expectCode("writable: read-only target", base, only("target", (s) => ({ ...s, role: AccountRole.READONLY })), 2000);
	await expectCode("mutable: another owner", base, only("pet", (s) => ({ ...s, owner: SYSTEM })), 3007);
	await expectCode("mutable: no room for a discriminator", base, only("pet", (s) => ({ ...s, data: new Uint8Array(4) })), 3001);
	await expectCode("mutable: another discriminator", base, only("pet", patch(0)), 3002);
	await expectCode("mutable: too little data", base, only("pet", (s) => ({ ...s, data: s.data.subarray(0, 20) })), 3003);
	await expectCode("mutable: read-only", base, only("pet", (s) => ({ ...s, role: AccountRole.READONLY })), 2000);
	await expectCode("external mint: another owner", base, only("mint", (s) => ({ ...s, owner: SYSTEM })), 3007);
	await expectCode("external token: read-only", base, only("token", (s) => ({ ...s, role: AccountRole.READONLY })), 2000);
	for (const at of [0, 31]) {
		await expectCode(`mutable: an owner that differs in byte ${at}`, base, only("pet", (s) => ({ ...s, owner: decoder.decode(flipped(bytesOf(PROGRAM), at)) })), 3007);
	}
	await expectCode("@hasOne: the account names another owner", by("@hasOne(owner)"), only("pet", patch(8)), 2001);
	await expectCode("@hasOne with an error: the account names another owner", by("@hasOne(owner, error)"), only("pet", patch(8)), "error: InvalidArgument");
	await expectCode("@address: another key", by("@address(const)"), only("program", (s) => ({ ...s, key: addressFrom("stranger") })), 2012);
	await expectCode("@address: off by the last byte", by("@address(const)"), only("program", (s) => ({ ...s, key: decoder.decode(flipped(bytesOf(SYSTEM), 31)) })), 2012);
	await expectCode("@address with an error: another key", by("@address(const, error)"), only("program", (s) => ({ ...s, key: addressFrom("stranger") })), "error: InvalidArgument");
	await expectCode("@address(sibling): another key", by("@address(sibling)"), only("target", (s) => ({ ...s, key: addressFrom("stranger") })), 2012);
	await expectCode("@seeds @bump(stored): another stored bump", by("@seeds @bump(stored)"), only("pet", patch(8 + 40)), 2006);
	await expectCode("@seeds @bump(stored): not at the PDA", by("@seeds @bump(stored)"), only("pet", (s) => ({ ...s, key: addressFrom("stranger") })), 2006);
	await expectCode("@seeds @bump: not at the canonical PDA", by("@seeds @bump"), only("pet", (s) => ({ ...s, key: addressFrom("stranger") })), 2006);
	await expectCode("@associated: another authority", by("@associated"), only("token", patch(32)), 2015);
	await expectCode("@associated: off the associated address", by("@associated"), only("token", (s) => ({ ...s, key: addressFrom("stranger") })), 2009);
	await expectCode("@tokenMint: another mint", by("@tokenMint"), only("token", patch(0)), 2014);
	await expectCode("@tokenAuthority: another authority", by("@tokenAuthority"), only("token", patch(32)), 2015);
	await expectCode("@constraint: the condition is false", by("@constraint"), only("pet", patch(8 + 32)), 2003);
	if (failures > 0) {
		console.error(`accountTableCost: ${failures} refusal(s) answered another code`);
		process.exit(1);
	}
	console.log(`[${form}] every refusal kept its code`);
}

async function hibernal() {
	const shapes = hibernalShapes().map((s, i) => ({ ...s, handler: `h${i}`, op: i + 1 }));
	const extra = `enum HibernalError { NotAuthority, NotTheOwner }

function hibernalError(error: HibernalError): ProgramError {
	return ProgramError.custom(6000 + (error as uint32));
}
`;
	const built = build("hibernal", programSource(shapes, DATAS, extra));
	const idle = await runOp(built.path, IDLE, DATAS, 0);
	const decorated = shapes.reduce((n, s) => n + s.fields.filter((f) => (f.decos ?? []).length).length, 0);
	console.log(`[${form}] ${shapes.length} instructions, ${shapes.reduce((n, s) => n + s.fields.length, 0)} fields (${decorated} decorated); .so ${built.sizes.so}, .text ${built.sizes.text}, .rodata ${built.sizes.rodata}; idle ${idle.units} CU`);
	let total = 0;
	for (const shape of shapes) {
		const outcome = await runOp(built.path, shape, DATAS, shape.op);
		if (!outcome.ok) throw new Error(`${shape.name}: ${outcome.error}`);
		console.log(`${shape.name.padEnd(28)}${pad(shape.fields.length, 4)} fields ${pad(outcome.units - idle.units, 7)} CU`);
		total += outcome.units - idle.units;
	}
	console.log(`total ${total} CU over ${shapes.length} instructions`);
}

const ESCROW_SEEDS = { d: "seeds", seeds: [{ text: "escrow" }, { key: "maker" }, { le: { of: "escrow", member: "seed", width: 8 } }], bump: "escrow.bump" };

function escrowShapes() {
	const token = (name, ...decos) => ({ name, type: "ExternalMutable<TokenAccount>", decos });
	const field = (name, type, ...decos) => ({ name, type, decos });
	const assoc = (mint, authority) => ({ d: "associated", mint, authority });
	return [
		{ name: "MakeAccounts", statement: "accounts<MakeAccounts>", fields: [
			field("maker", "WritableSigner"), field("mintA", "External<Mint>"), field("mintB", "External<Mint>"),
			token("makerAtaA", assoc("mintA", "maker")), field("escrow", "Writable"), field("vault", "Writable"),
			field("associatedTokenProgram", "Program<AssociatedToken>"), field("tokenProgram", "Account"), field("systemProgram", "Program<System>"),
		] },
		{ name: "TakeAccounts", statement: "accounts<TakeAccounts>", fields: [
			field("taker", "WritableSigner"), field("maker", "Writable"), field("mintA", "External<Mint>"), field("mintB", "External<Mint>"),
			token("takerAtaA", assoc("mintA", "taker")), token("takerAtaB", assoc("mintB", "taker")), token("makerAtaB", assoc("mintB", "maker")),
			field("escrow", "Mutable<Escrow>", ESCROW_SEEDS, { d: "hasOne", name: "maker" }, { d: "hasOne", name: "mintA" }, { d: "hasOne", name: "mintB" }),
			token("vault", assoc("mintA", "escrow")), field("tokenProgram", "Account"), field("systemProgram", "Program<System>"),
		] },
		{ name: "RefundAccounts", statement: "accounts<RefundAccounts>", fields: [
			field("maker", "WritableSigner"), field("mintA", "External<Mint>"), token("makerAtaA", assoc("mintA", "maker")),
			field("escrow", "Mutable<Escrow>", ESCROW_SEEDS, { d: "hasOne", name: "maker" }, { d: "hasOne", name: "mintA" }),
			token("vault", assoc("mintA", "escrow")), field("tokenProgram", "Account"), field("systemProgram", "Program<System>"),
		] },
	];
}

async function escrow() {
	const root = join(HERE, "..", "..", "examples", "escrow");
	const dir = join(work, form, "escrow");
	rmSync(dir, { recursive: true, force: true });
	mkdirSync(dir, { recursive: true });
	let source = readFileSync(join(root, "program.ms"), "utf8");
	if (form !== "std") {
		let consts = "";
		for (const shape of escrowShapes()) {
			const parts = statementsOf(shape, DATAS_ESCROW);
			consts += parts.consts;
			const call = `\tconst x = try ${shape.statement}();\n`;
			const original = new RegExp(`[ \t]*const x = try ${shape.statement}\\(\\);\\n`);
			if (!original.test(source)) throw new Error(`the escrow no longer has ${shape.statement}`);
			void call;
			source = source.replace(original, `${parts.body}\tconst x = $accounts;\n`);
		}
		const imports = form === "table"
			? 'import { bytesAddress } from "std/solana/seed";\nimport { failed, verifiedAccounts, verifiedConstraints } from "./accountTableProto";\nimport { word } from "std/solana";\n'
			: 'import { exclusiveWritable, word } from "std/solana";\nimport { bytesAddress, seedBytes, seedKey, seedText } from "std/solana/seed";\nimport { anyCode, associatedCode, delegatedCode, failed, keysCode, mutableCode, ownedCode, programCode, seedsCanonicalCode, seedsGivenCode, signerCode, systemCode, tokenAuthorityCode, tokenMintCode, writableCode, writableSignerCode } from "./accountTableProto";\n';
		source = source.replace('import { Escrow, EscrowError', `${imports}function raise(error: ProgramError): Result<void, ProgramError> {\n\treturn Result.err(error);\n}\n\n${consts}import { Escrow, EscrowError`);
		copyFileSync(join(HERE, "accountTableProto.cms"), join(dir, "accountTableProto.cms"));
	}
	writeFileSync(join(dir, "program.ms"), source);
	copyFileSync(join(root, "layout.ms"), join(dir, "layout.ms"));
	const out = join(dir, "escrow.so");
	try {
		execFileSync(msc, ["build", join(dir, "program.ms"), "--os=solana", `--output=${out}`], { cwd: dir, stdio: ["ignore", "pipe", "pipe"], maxBuffer: 1 << 28 });
	} catch (error) {
		const text = `${error.stdout ?? ""}${error.stderr ?? ""}`;
		throw new Error(`the escrow did not build:\n${text.split("\n").filter((l) => /error/.test(l)).slice(0, 14).join("\n")}`);
	}
	const sizes = sizesOf(out);
	console.log(`[${form}] escrow .so ${sizes.so}, .text ${sizes.text}, .rodata ${sizes.rodata}`);
	const idl = execFileSync(msc, ["run", join(root, "idl.cms")], { cwd: dir, maxBuffer: 1 << 26 }).toString();
	writeFileSync(join(dir, "escrow.json"), idl);
	let report;
	try {
		report = execFileSync("node", [join(HERE, "escrow.mjs"), out, join(dir, "escrow.json")], { cwd: HERE, maxBuffer: 1 << 26 }).toString();
	} catch (error) {
		report = `${error.stdout ?? ""}${error.stderr ?? ""}`;
		console.log(report.split("\n").filter((l) => /FAILED|CU|escrow:/.test(l)).join("\n"));
		process.exit(1);
	}
	console.log(report.split("\n").filter((l) => /CU|escrow:/.test(l)).join("\n"));
}

const DATAS_ESCROW = {};

if (suite === "matrix") await matrix();
if (suite === "decorators") await decorators();
if (suite === "hibernal") await hibernal();
if (suite === "refusals") await refusals();
if (suite === "escrow") await escrow();
