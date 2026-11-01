import { readFile } from "std/fs";
import { Buffer } from "std/core/buffer";
import { CryptoError, fromHex, toHex } from "std/crypto";
import { newOutputBuffer, outputBytes } from "std/crypto/outputBuffer";
import { JsonKind, getDynamicField, asString, asInt32, at, length, parseJson } from "std/core/json";

const ZERO_SHARED = "0".repeat(64);

export type X25519Raw = (output: Ptr<uint8>, scalar: Ptr<uint8>, point: Ptr<uint8>) => void;
export type X25519SharedSecret = (scalar: Buffer, point: Buffer) => Result<Buffer, CryptoError>;

export struct X25519Case {
	tcId: int32;
	comment: string;
	flags: string[];
	scalar: string;
	point: string;
	shared: string;
	result: string;
}

export class X25519Tally {
	total: int32 = 0;
	passed: int32 = 0;
	failed: int32 = 0;
	valid: int32 = 0;
	acceptableNonZero: int32 = 0;
	acceptableZero: int32 = 0;
	failures: string[] = [];
}

function isHex32(hex: string): boolean {
	if (hex.length != 64) return false;
	for (const ch of hex.asBytes()) {
		const digit = (ch >= 48 && ch <= 57) || (ch >= 97 && ch <= 102);
		if (!digit) return false;
	}
	return true;
}

export function loadX25519Cases(path: string): Result<X25519Case[], string> {
	const text = readFile(path);
	if (!text.ok) return Result.err(`cannot read ${path}`);
	const parsed = parseJson(text.value);
	if (!parsed.ok) return Result.err(`cannot parse ${path}: ${parsed.error}`);
	const cases: X25519Case[] = [];
	const groups = parsed.value.getDynamicField("testGroups");
	for (let g = 0; g < groups.length(); g++) {
		const tests = groups.at(g).getDynamicField("tests");
		for (let t = 0; t < tests.length(); t++) {
			const test = tests.at(t);
			const flags: string[] = [];
			const flagList = test.getDynamicField("flags");
			for (let f = 0; f < flagList.length(); f++) flags.push(flagList.at(f).asString());
			const item: X25519Case = {
				tcId: test.getDynamicField("tcId").asInt32(),
				comment: test.getDynamicField("comment").asString(),
				flags: flags,
				scalar: test.getDynamicField("private").asString(),
				point: test.getDynamicField("public").asString(),
				shared: test.getDynamicField("shared").asString(),
				result: test.getDynamicField("result").asString(),
			};
			if (!isHex32(item.scalar) || !isHex32(item.point) || !isHex32(item.shared)) {
				return Result.err(`${path} tcId ${item.tcId}: scalar, point and shared must be 32-byte lowercase hex`);
			}
			if (item.result != "valid" && item.result != "acceptable") {
				return Result.err(`${path} tcId ${item.tcId}: unexpected result ${item.result}`);
			}
			cases.push(item);
		}
	}
	const declared = parsed.value.getDynamicField("numberOfTests");
	if (declared.kind == JsonKind.Int && declared.asInt32() != cases.length) {
		return Result.err(`${path}: numberOfTests ${declared.asInt32()} but ${cases.length} cases`);
	}
	return Result.ok(cases);
}

export function countFlag(cases: X25519Case[], flag: string): int32 {
	let count: int32 = 0;
	for (const item of cases) {
		if (item.flags.includes(flag)) count++;
	}
	return count;
}

function classify(item: X25519Case, tally: X25519Tally): void {
	tally.total++;
	if (item.result == "valid") tally.valid++;
	else if (item.shared == ZERO_SHARED) tally.acceptableZero++;
	else tally.acceptableNonZero++;
}

function record(tally: X25519Tally, item: X25519Case, got: string): void {
	if (got == item.shared) {
		tally.passed++;
		return;
	}
	tally.failed++;
	tally.failures.push(
		`tcId ${item.tcId} [${item.flags.join(",")}] ${item.comment}: expected ${item.shared} got ${got}`,
	);
}

// Raw kernel: every case, the all-zero outputs included, must equal `shared` (a `void` kernel cannot refuse).
export function checkRawX25519(cases: X25519Case[], scalarMult: X25519Raw): X25519Tally {
	const tally = new X25519Tally();
	for (const item of cases) {
		classify(item, tally);
		const scalar = fromHex(item.scalar);
		const point = fromHex(item.point);
		const output = newOutputBuffer(32);
		scalarMult(outputBytes(output), outputBytes(scalar), outputBytes(point));
		record(tally, item, toHex(output));
	}
	return tally;
}

// API: an all-zero `shared` must be refused. Wycheproof `acceptable` would also allow returning the
// zeros, which this API contract does not. Every other `valid` or `acceptable` case must return exactly
// `shared`, though Wycheproof would also allow refusing it.
export function checkSharedSecretX25519(
	cases: X25519Case[],
	sharedSecret: X25519SharedSecret,
): X25519Tally {
	const tally = new X25519Tally();
	for (const item of cases) {
		classify(item, tally);
		const result = sharedSecret(fromHex(item.scalar), fromHex(item.point));
		if (item.shared != ZERO_SHARED) {
			record(tally, item, result.ok ? toHex(result.value) : "refused");
		} else if (result.ok) {
			record(tally, item, `returned ${toHex(result.value)} instead of refusing`);
		} else {
			tally.passed++;
		}
	}
	return tally;
}

export function withWrongExpected(cases: X25519Case[], index: int32): X25519Case[] {
	const out: X25519Case[] = [];
	for (let i = 0; i < cases.length; i++) {
		const item = cases[i];
		if (i != index) {
			out.push(item);
			continue;
		}
		const flipped = item.shared.startsWith("0") ? "1" : "0";
		out.push({
			tcId: item.tcId,
			comment: item.comment,
			flags: item.flags,
			scalar: item.scalar,
			point: item.point,
			shared: flipped + item.shared.slice(1),
			result: item.result,
		});
	}
	return out;
}

export function describeX25519Tally(name: string, tally: X25519Tally): string {
	return `${name}: ${tally.total} cases, ${tally.passed} passed, ${tally.failed} failed ` +
		`(valid ${tally.valid}, acceptable non-zero ${tally.acceptableNonZero}, ` +
		`acceptable all-zero ${tally.acceptableZero})`;
}

export function requireCleanX25519(name: string, tally: X25519Tally): void {
	if (tally.failed == 0) return;
	const shown = tally.failures.slice(0, 5).join("\n");
	throw new Error(`${describeX25519Tally(name, tally)}\n${shown}`);
}
