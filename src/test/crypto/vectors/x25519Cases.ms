import { readFile } from "std/fs";
import { Buffer } from "std/core/buffer";
import { CryptoError, fromHex, toHex } from "std/crypto";
import { newOutputBuffer, outputBytes } from "std/crypto/outputBuffer";
import { JsonKind, JsonValue, getDynamicField, asString, asInt32, at, length, parseJson } from "std/core/json";

const ZERO_SHARED = "0".repeat(64);

export function decodeX25519Hex(hex: string): Buffer {
	const decoded = fromHex(hex);
	if (!decoded.ok) throw new Error("X25519 fixture hex was refused");
	return decoded.value;
}

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

function field(value: JsonValue, name: string, kind: JsonKind, where: string): Result<JsonValue, string> {
	const found = value.getDynamicField(name);
	if (found.kind != kind) return Result.err(`${where}: ${name} is missing or has the wrong type`);
	return Result.ok(found);
}

export function parseX25519Cases(text: string, name: string): Result<X25519Case[], string> {
	const parsed = parseJson(text);
	if (!parsed.ok) return Result.err(`cannot parse ${name}: ${parsed.error}`);
	const root = parsed.value;
	if (root.kind != JsonKind.Object) return Result.err(`${name}: top level is not an object`);
	const declared = field(root, "numberOfTests", JsonKind.Int, name);
	if (!declared.ok) return Result.err(declared.error);
	const groups = field(root, "testGroups", JsonKind.Array, name);
	if (!groups.ok) return Result.err(groups.error);
	const cases: X25519Case[] = [];
	for (let g = 0; g < groups.value.length(); g++) {
		const tests = field(groups.value.at(g), "tests", JsonKind.Array, `${name} group ${g}`);
		if (!tests.ok) return Result.err(tests.error);
		for (let t = 0; t < tests.value.length(); t++) {
			const test = tests.value.at(t);
			const where = `${name} group ${g} test ${t}`;
			const tcId = field(test, "tcId", JsonKind.Int, where);
			const comment = field(test, "comment", JsonKind.String, where);
			const flagList = field(test, "flags", JsonKind.Array, where);
			const scalar = field(test, "private", JsonKind.String, where);
			const point = field(test, "public", JsonKind.String, where);
			const shared = field(test, "shared", JsonKind.String, where);
			const result = field(test, "result", JsonKind.String, where);
			if (!tcId.ok) return Result.err(tcId.error);
			if (!comment.ok) return Result.err(comment.error);
			if (!flagList.ok) return Result.err(flagList.error);
			if (!scalar.ok) return Result.err(scalar.error);
			if (!point.ok) return Result.err(point.error);
			if (!shared.ok) return Result.err(shared.error);
			if (!result.ok) return Result.err(result.error);
			const flags: string[] = [];
			for (let f = 0; f < flagList.value.length(); f++) flags.push(flagList.value.at(f).asString());
			const item: X25519Case = {
				tcId: tcId.value.asInt32(),
				comment: comment.value.asString(),
				flags: flags,
				scalar: scalar.value.asString(),
				point: point.value.asString(),
				shared: shared.value.asString(),
				result: result.value.asString(),
			};
			if (!isHex32(item.scalar) || !isHex32(item.point) || !isHex32(item.shared)) {
				return Result.err(`${name} tcId ${item.tcId}: scalar, point and shared must be 32-byte lowercase hex`);
			}
			if (item.result != "valid" && item.result != "acceptable") {
				return Result.err(`${name} tcId ${item.tcId}: unexpected result ${item.result}`);
			}
			cases.push(item);
		}
	}
	if (cases.length == 0) return Result.err(`${name}: no cases`);
	if (declared.value.asInt32() != cases.length) {
		return Result.err(`${name}: numberOfTests ${declared.value.asInt32()} but ${cases.length} cases`);
	}
	return Result.ok(cases);
}

export function loadX25519Cases(path: string): Result<X25519Case[], string> {
	const text = readFile(path);
	if (!text.ok) return Result.err(`cannot read ${path}`);
	return parseX25519Cases(text.value, path);
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

function fail(tally: X25519Tally, item: X25519Case, detail: string): void {
	tally.failed++;
	tally.failures.push(`tcId ${item.tcId} [${item.flags.join(",")}] ${item.comment}: ${detail}`);
}

function record(tally: X25519Tally, item: X25519Case, got: string): void {
	if (got == item.shared) {
		tally.passed++;
		return;
	}
	fail(tally, item, `expected ${item.shared} got ${got}`);
}

export function checkRawX25519(cases: X25519Case[], scalarMult: X25519Raw): X25519Tally {
	const tally = new X25519Tally();
	for (const item of cases) {
		classify(item, tally);
		const scalar = decodeX25519Hex(item.scalar);
		const point = decodeX25519Hex(item.point);
		const output = newOutputBuffer(32);
		scalarMult(outputBytes(output), outputBytes(scalar), outputBytes(point));
		const got = toHex(output);
		if (got != item.shared) {
			fail(tally, item, `expected ${item.shared} got ${got}`);
		} else if (toHex(scalar) != item.scalar) {
			fail(tally, item, `kernel modified the scalar input to ${toHex(scalar)}`);
		} else if (toHex(point) != item.point) {
			fail(tally, item, `kernel modified the point input to ${toHex(point)}`);
		} else {
			tally.passed++;
		}
	}
	return tally;
}

export function checkSharedSecretX25519(
	cases: X25519Case[],
	sharedSecret: X25519SharedSecret,
): X25519Tally {
	const tally = new X25519Tally();
	for (const item of cases) {
		classify(item, tally);
		const result = sharedSecret(
			decodeX25519Hex(item.scalar),
			decodeX25519Hex(item.point),
		);
		if (item.shared != ZERO_SHARED) {
			record(tally, item, result.ok ? toHex(result.value) : "refused");
		} else if (result.ok) {
			fail(tally, item, `returned ${toHex(result.value)} instead of refusing`);
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
