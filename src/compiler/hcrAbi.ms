import { Type, TypeKind } from "../ast/node";
import { createFunction, createPrimitive, int32Type, stringType } from "../checker/types";
import { monoTypeKey } from "../monomorphize/registry";
import { djb2, fingerprint, hashToHex } from "std/hash";

export const HCR_ABI_VERSION: int32 = 1;

export struct HcrAbiExport {
	id: string;
	symbol: string;
	signature: string;
}

export struct HcrModuleAbi {
	version: int32;
	moduleId: string;
	targetKey: string;
	gcMode: string;
	toolchainKey: string;
	dependencies: string[];
	exports: HcrAbiExport[];
}

export function hcrSignatureKey(t: Type | null): string {
	return monoTypeKey(t);
}

export function hcrExportId(moduleId: string, symbol: string): string {
	return `${moduleId}::${symbol}`;
}

export function createHcrAbiExport(moduleId: string, symbol: string, signature: string): HcrAbiExport {
	return {
		id: hcrExportId(moduleId, symbol),
		symbol,
		signature,
	};
}

function sortStrings(values: string[]): void {
	for (let i = 1; i < values.length; i += 1) {
		const value = values[i];
		let j = i - 1;
		while (j >= 0 && values[j] > value) {
			values[j + 1] = values[j];
			j -= 1;
		}
		values[j + 1] = value;
	}
}

function exportAfter(a: HcrAbiExport, b: HcrAbiExport): boolean {
	if (a.id != b.id) return a.id > b.id;
	if (a.symbol != b.symbol) return a.symbol > b.symbol;
	return a.signature > b.signature;
}

function sortExports(values: HcrAbiExport[]): void {
	for (let i = 1; i < values.length; i += 1) {
		const value = values[i];
		let j = i - 1;
		while (j >= 0 && exportAfter(values[j], value)) {
			values[j + 1] = values[j];
			j -= 1;
		}
		values[j + 1] = value;
	}
}

function copyDependencies(values: string[]): string[] {
	const copied: string[] = [];
	for (const value of values) {
		if (value != "") copied.push(value);
	}
	sortStrings(copied);
	const unique: string[] = [];
	for (const value of copied) {
		if (unique.length == 0 || unique[unique.length - 1] != value) unique.push(value);
	}
	return unique;
}

function copyExports(values: HcrAbiExport[]): HcrAbiExport[] {
	const copied: HcrAbiExport[] = [];
	for (const value of values) copied.push(value);
	sortExports(copied);
	return copied;
}

export function buildHcrModuleAbi(
	moduleId: string,
	targetKey: string,
	gcMode: string,
	toolchainKey: string,
	dependencies: string[],
	exports: HcrAbiExport[],
): Result<HcrModuleAbi, string> {
	if (moduleId == "") return Result.err("HCR ABI manifest requires a module id");
	if (targetKey == "") return Result.err(`HCR ABI manifest '${moduleId}' requires a target key`);
	if (gcMode == "") return Result.err(`HCR ABI manifest '${moduleId}' requires a GC mode`);
	if (toolchainKey == "") return Result.err(`HCR ABI manifest '${moduleId}' requires a toolchain key`);

	const sortedExports = copyExports(exports);
	for (let i = 0; i < sortedExports.length; i += 1) {
		const item = sortedExports[i];
		if (item.id == "" || item.symbol == "" || item.signature == "") {
			return Result.err(`HCR ABI manifest '${moduleId}' has an incomplete export`);
		}
		if (i > 0 && sortedExports[i - 1].id == item.id) {
			return Result.err(`HCR ABI manifest '${moduleId}' has duplicate export '${item.id}'`);
		}
	}

	return Result.ok({
		version: HCR_ABI_VERSION,
		moduleId,
		targetKey,
		gcMode,
		toolchainKey,
		dependencies: copyDependencies(dependencies),
		exports: sortedExports,
	});
}

function appendKeyPart(key: string, value: string): string {
	return `${key}${value.byteLength}:${value}`;
}

export function hcrAbiFingerprint(manifest: HcrModuleAbi): string {
	let key = appendKeyPart("", manifest.version.toString());
	key = appendKeyPart(key, manifest.moduleId);
	key = appendKeyPart(key, manifest.targetKey);
	key = appendKeyPart(key, manifest.gcMode);
	key = appendKeyPart(key, manifest.toolchainKey);
	key = appendKeyPart(key, `dependencies:${manifest.dependencies.length}`);
	for (const dependency of manifest.dependencies) key = appendKeyPart(key, dependency);
	key = appendKeyPart(key, `exports:${manifest.exports.length}`);
	for (const item of manifest.exports) {
		key = appendKeyPart(key, item.id);
		key = appendKeyPart(key, item.symbol);
		key = appendKeyPart(key, item.signature);
	}
	return `${hashToHex(djb2(key))}_${hashToHex(fingerprint(key))}`;
}

test "HCR ABI manifest is deterministic across discovery order" {
	const a = createHcrAbiExport("logic", "logic_value", "func():int32");
	const b = createHcrAbiExport("logic", "logic_label", "func(int32):string");
	const first = buildHcrModuleAbi("logic", "windows-x64", "drc", "toolchain", ["std/io", "app", "std/io"], [a, b]);
	const second = buildHcrModuleAbi("logic", "windows-x64", "drc", "toolchain", ["app", "std/io"], [b, a]);
	assert first.ok;
	assert second.ok;
	assert hcrAbiFingerprint(first.value) == hcrAbiFingerprint(second.value);
	assert first.value.dependencies.length == 2;
	assert first.value.dependencies[0] == "app";
	assert first.value.exports[0].symbol == "logic_label";
}

test "HCR ABI signature ignores parameter names and detects width changes" {
	const base = createFunction([int32Type(), stringType()], ["value", "label"], int32Type());
	const renamed = createFunction([int32Type(), stringType()], ["n", "s"], int32Type());
	const widened = createFunction([createPrimitive(TypeKind.Int64), stringType()], ["value", "label"], int32Type());
	assert hcrSignatureKey(base) == hcrSignatureKey(renamed);
	assert hcrSignatureKey(base) != hcrSignatureKey(widened);
}

test "HCR ABI manifest rejects duplicate stable export ids" {
	const a = createHcrAbiExport("logic", "logic_value", "func():int32");
	const b = createHcrAbiExport("logic", "logic_value", "func():int64");
	const result = buildHcrModuleAbi("logic", "linux-x64", "orc", "toolchain", [], [a, b]);
	assert !result.ok;
}

test "HCR ABI fingerprint separates dependency and export sections" {
	const deps = buildHcrModuleAbi("logic", "linux-x64", "drc", "toolchain", ["a", "b", "c"], []);
	const slot: HcrAbiExport = { id: "a", symbol: "b", signature: "c" };
	const exports = buildHcrModuleAbi("logic", "linux-x64", "drc", "toolchain", [], [slot]);
	assert deps.ok;
	assert exports.ok;
	assert hcrAbiFingerprint(deps.value) != hcrAbiFingerprint(exports.value);
}
