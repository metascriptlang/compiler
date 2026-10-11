import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { dirname, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

// node tools/solana/codamaPdaCheck.mjs <idl.json>; the IDL is the output of `msc run std/solana/idlTest.ms`.
// @codama/nodes-from-anchor resolves from CODAMA_DIR (a directory holding node_modules), else tools/solana.
const here = dirname(fileURLToPath(import.meta.url));
const modules = createRequire(resolve(process.env.CODAMA_DIR ?? here, "package.json"));
const { rootNodeFromAnchor } = await import(pathToFileURL(modules.resolve("@codama/nodes-from-anchor")));

const idl = JSON.parse(readFileSync(process.argv[2], "utf8"));
const program = rootNodeFromAnchor(idl).program;

const escrow = program.pdas.find((pda) => pda.name === "escrow");
assert.ok(escrow, "the IDL's escrow seeds give a pdaNode named escrow");
assert.deepEqual(escrow.seeds.map((seed) => seed.kind), ["constantPdaSeedNode", "variablePdaSeedNode", "variablePdaSeedNode"]);
assert.equal(escrow.seeds[1].name, "maker");
assert.equal(escrow.seeds[1].type.kind, "publicKeyTypeNode");
assert.equal(escrow.seeds[2].name, "seed");
assert.equal(escrow.seeds[2].type.format, "u64");

const make = program.instructions.find((instruction) => instruction.name === "make");
const account = make.accounts.find((a) => a.name === "escrow");
assert.equal(account.defaultValue.kind, "pdaValueNode");
assert.equal(account.defaultValue.pda.name, "escrow");
assert.deepEqual(
  account.defaultValue.seeds.map((seed) => [seed.name, seed.value.kind]),
  [["maker", "accountValueNode"], ["seed", "argumentValueNode"]],
);

const system = make.accounts.find((a) => a.name === "systemProgram");
assert.equal(system.defaultValue.kind, "publicKeyValueNode");
assert.equal(system.defaultValue.publicKey, "11111111111111111111111111111111");
console.log("codama pda check: ok");
