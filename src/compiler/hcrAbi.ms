import { Type, TypeKind } from "../ast/node";
import { createFunction, createPrimitive, int32Type, stringType } from "../checker/types";
import { monoTypeKey } from "../monomorphize/registry";
import { djb2, fingerprint, hashToHex } from "std/hash";
import { JsonKind, JsonValue, jsonArray, jsonNumber, jsonObject, jsonString, parseJson, stringifyPretty } from "std/core/json";

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

export enum HcrReloadKind {
	ReloadModule,
	ReloadDependents,
	RestartRequired,
}

export enum HcrReloadReason {
	ImplementationChanged,
	DependenciesChanged,
	ExportAdded,
	ExportRemoved,
	ExportSignatureChanged,
	ExportSymbolChanged,
	ManifestVersionChanged,
	ModuleIdentityChanged,
	TargetChanged,
	GcModeChanged,
	ModuleAdded,
	ModuleRemoved,
	ToolchainChanged,
}

export struct HcrReloadDecision {
	kind: HcrReloadKind;
	reason: HcrReloadReason;
	subject: string;
}

export function hcrSignatureKey(t: Type | null): string {
	return monoTypeKey(t);
}

export function hcrExportId(moduleId: string, symbol: string): string {
	return `${moduleId}::${symbol}`;
}

export function createHcrAbiExport(moduleId: string, symbol: string, signature: string, slot: string = ""): HcrAbiExport {
	return {
		id: hcrExportId(moduleId, slot != "" ? slot : symbol),
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

function reloadDecision(kind: HcrReloadKind, reason: HcrReloadReason, subject: string): HcrReloadDecision {
	return { kind, reason, subject };
}

function sameStrings(a: string[], b: string[]): boolean {
	if (a.length != b.length) return false;
	for (let i = 0; i < a.length; i += 1) {
		if (a[i] != b[i]) return false;
	}
	return true;
}

export function classifyHcrReload(current: HcrModuleAbi, candidate: HcrModuleAbi): HcrReloadDecision {
	if (current.version != candidate.version) {
		return reloadDecision(HcrReloadKind.RestartRequired, HcrReloadReason.ManifestVersionChanged,
			`${current.version} -> ${candidate.version}`);
	}
	if (current.moduleId != candidate.moduleId) {
		return reloadDecision(HcrReloadKind.RestartRequired, HcrReloadReason.ModuleIdentityChanged,
			`${current.moduleId} -> ${candidate.moduleId}`);
	}
	if (current.targetKey != candidate.targetKey) {
		return reloadDecision(HcrReloadKind.RestartRequired, HcrReloadReason.TargetChanged,
			`${current.targetKey} -> ${candidate.targetKey}`);
	}
	if (current.gcMode != candidate.gcMode) {
		return reloadDecision(HcrReloadKind.RestartRequired, HcrReloadReason.GcModeChanged,
			`${current.gcMode} -> ${candidate.gcMode}`);
	}
	if (current.toolchainKey != candidate.toolchainKey) {
		return reloadDecision(HcrReloadKind.RestartRequired, HcrReloadReason.ToolchainChanged,
			`${current.toolchainKey} -> ${candidate.toolchainKey}`);
	}

	let oldIndex: int32 = 0;
	let newIndex: int32 = 0;
	while (oldIndex < current.exports.length && newIndex < candidate.exports.length) {
		const oldExport = current.exports[oldIndex];
		const newExport = candidate.exports[newIndex];
		if (oldExport.id < newExport.id) {
			return reloadDecision(HcrReloadKind.ReloadDependents, HcrReloadReason.ExportRemoved, oldExport.id);
		}
		if (oldExport.id > newExport.id) {
			return reloadDecision(HcrReloadKind.ReloadDependents, HcrReloadReason.ExportAdded, newExport.id);
		}
		if (oldExport.symbol != newExport.symbol) {
			return reloadDecision(HcrReloadKind.ReloadDependents, HcrReloadReason.ExportSymbolChanged, oldExport.id);
		}
		if (oldExport.signature != newExport.signature) {
			return reloadDecision(HcrReloadKind.ReloadDependents, HcrReloadReason.ExportSignatureChanged, oldExport.id);
		}
		oldIndex += 1;
		newIndex += 1;
	}
	if (oldIndex < current.exports.length) {
		return reloadDecision(HcrReloadKind.ReloadDependents, HcrReloadReason.ExportRemoved,
			current.exports[oldIndex].id);
	}
	if (newIndex < candidate.exports.length) {
		return reloadDecision(HcrReloadKind.ReloadDependents, HcrReloadReason.ExportAdded,
			candidate.exports[newIndex].id);
	}
	if (!sameStrings(current.dependencies, candidate.dependencies)) {
		return reloadDecision(HcrReloadKind.ReloadModule, HcrReloadReason.DependenciesChanged, candidate.moduleId);
	}
	return reloadDecision(HcrReloadKind.ReloadModule, HcrReloadReason.ImplementationChanged, candidate.moduleId);
}

export function hcrReloadReasonText(reason: HcrReloadReason): string {
	return match (reason) {
		HcrReloadReason.ImplementationChanged => "implementation changed",
		HcrReloadReason.DependenciesChanged => "dependencies changed",
		HcrReloadReason.ExportAdded => "export added",
		HcrReloadReason.ExportRemoved => "export removed",
		HcrReloadReason.ExportSignatureChanged => "export signature changed",
		HcrReloadReason.ExportSymbolChanged => "export symbol changed",
		HcrReloadReason.ManifestVersionChanged => "manifest version changed",
		HcrReloadReason.ModuleIdentityChanged => "module identity changed",
		HcrReloadReason.TargetChanged => "target changed",
		HcrReloadReason.GcModeChanged => "GC mode changed",
		HcrReloadReason.ToolchainChanged => "toolchain changed",
		HcrReloadReason.ModuleAdded => "module added",
		HcrReloadReason.ModuleRemoved => "module removed",
	};
}

export function hcrReloadDiagnostic(decision: HcrReloadDecision): string {
	const action = match (decision.kind) {
		HcrReloadKind.ReloadModule => "reload module",
		HcrReloadKind.ReloadDependents => "reload dependents",
		HcrReloadKind.RestartRequired => "restart required",
	};
	return `HCR ${action}: ${hcrReloadReasonText(decision.reason)} (${decision.subject})`;
}
function sortManifests(values: HcrModuleAbi[]): void {
	for (let i = 1; i < values.length; i += 1) {
		const value = values[i];
		let j = i - 1;
		while (j >= 0 && values[j].moduleId > value.moduleId) {
			values[j + 1] = values[j];
			j -= 1;
		}
		values[j + 1] = value;
	}
}

function jsonStringArray(values: string[]): JsonValue {
	const items: JsonValue[] = [];
	for (const value of values) items.push(jsonString(value));
	return jsonArray(items);
}

function exportJson(value: HcrAbiExport): JsonValue {
	return jsonObject(
		["id", "symbol", "signature"],
		[jsonString(value.id), jsonString(value.symbol), jsonString(value.signature)],
	);
}

function manifestJson(value: HcrModuleAbi): JsonValue {
	const exportValues: JsonValue[] = [];
	for (const item of value.exports) exportValues.push(exportJson(item));
	return jsonObject(
		["version", "moduleId", "targetKey", "gcMode", "toolchainKey", "dependencies", "exports"],
		[
			jsonNumber(value.version),
			jsonString(value.moduleId),
			jsonString(value.targetKey),
			jsonString(value.gcMode),
			jsonString(value.toolchainKey),
			jsonStringArray(value.dependencies),
			jsonArray(exportValues),
		],
	);
}

export function serializeHcrAbiBundle(manifests: HcrModuleAbi[]): Result<string, string> {
	const sorted: HcrModuleAbi[] = [];
	for (const manifest of manifests) sorted.push(manifest);
	sortManifests(sorted);
	const values: JsonValue[] = [];
	for (let i = 0; i < sorted.length; i += 1) {
		if (i > 0 && sorted[i - 1].moduleId == sorted[i].moduleId) {
			return Result.err(`duplicate HCR ABI module '${sorted[i].moduleId}'`);
		}
		values.push(manifestJson(sorted[i]));
	}
	const root = jsonObject(
		["version", "modules"],
		[jsonNumber(HCR_ABI_VERSION), jsonArray(values)],
	);
	return Result.ok(stringifyPretty(root, 2) + "\n");
}

function jsonField(obj: JsonValue, name: string): JsonValue {
	if (obj == null || obj.kind != JsonKind.Object) return null as unknown as JsonValue;
	for (let i = 0; i < obj.keys.length; i += 1) {
		if (obj.keys[i] == name && i < obj.values.length) return obj.values[i];
	}
	return null as unknown as JsonValue;
}

function jsonIntField(obj: JsonValue, name: string): int32 {
	const value = jsonField(obj, name);
	if (value == null) return -1;
	if (value.kind == JsonKind.Int) return value.intVal as int32;
	if (value.kind == JsonKind.Number) return value.numVal as int32;
	return -1;
}

function jsonStringField(obj: JsonValue, name: string): string {
	const value = jsonField(obj, name);
	if (value != null && value.kind == JsonKind.String) return value.strVal;
	return "";
}

function parseStringArray(obj: JsonValue, name: string): Result<string[], string> {
	const value = jsonField(obj, name);
	if (value == null || value.kind != JsonKind.Array) return Result.err(`field '${name}' must be an array`);
	const result: string[] = [];
	for (const item of value.items) {
		if (item == null || item.kind != JsonKind.String) return Result.err(`field '${name}' must contain strings`);
		result.push(item.strVal);
	}
	return Result.ok(result);
}

function parseExports(obj: JsonValue): Result<HcrAbiExport[], string> {
	const value = jsonField(obj, "exports");
	if (value == null || value.kind != JsonKind.Array) return Result.err("field 'exports' must be an array");
	const exports: HcrAbiExport[] = [];
	for (const item of value.items) {
		if (item == null || item.kind != JsonKind.Object) return Result.err("field 'exports' must contain objects");
		const id = jsonStringField(item, "id");
		const symbol = jsonStringField(item, "symbol");
		const signature = jsonStringField(item, "signature");
		if (id == "" || symbol == "" || signature == "") return Result.err("export entries require id, symbol and signature");
		exports.push({ id, symbol, signature });
	}
	return Result.ok(exports);
}

export function parseHcrAbiBundle(content: string): Result<HcrModuleAbi[], string> {
	const parsed = parseJson(content);
	if (!parsed.ok) return Result.err("invalid JSON");
	const root = parsed.value;
	if (root == null || root.kind != JsonKind.Object) return Result.err("root must be an object");
	if (jsonIntField(root, "version") != HCR_ABI_VERSION) return Result.err("unsupported bundle version");
	const modules = jsonField(root, "modules");
	if (modules == null || modules.kind != JsonKind.Array) return Result.err("field 'modules' must be an array");

	const manifests: HcrModuleAbi[] = [];
	for (const item of modules.items) {
		if (item == null || item.kind != JsonKind.Object) return Result.err("field 'modules' must contain objects");
		const version = jsonIntField(item, "version");
		if (version != HCR_ABI_VERSION) return Result.err("unsupported module manifest version");
		const dependencies = parseStringArray(item, "dependencies");
		if (!dependencies.ok) return Result.err(dependencies.error);
		const exports = parseExports(item);
		if (!exports.ok) return Result.err(exports.error);
		const built = buildHcrModuleAbi(
			jsonStringField(item, "moduleId"),
			jsonStringField(item, "targetKey"),
			jsonStringField(item, "gcMode"),
			jsonStringField(item, "toolchainKey"),
			dependencies.value,
			exports.value,
		);
		if (!built.ok) return Result.err(built.error);
		manifests.push(built.value);
	}
	sortManifests(manifests);
	for (let i = 1; i < manifests.length; i += 1) {
		if (manifests[i - 1].moduleId == manifests[i].moduleId) {
			return Result.err(`duplicate HCR ABI module '${manifests[i].moduleId}'`);
		}
	}
	return Result.ok(manifests);
}


test "HCR ABI bundle round-trips in module order" {
	const a = classifierTestManifest("windows-x64", "drc", "toolchain", ["logic"], []);
	const value = createHcrAbiExport("logic", "logic_value", "func():int32");
	const logic = classifierTestManifest("windows-x64", "drc", "toolchain", [], [value]);
	a.moduleId = "app";
	const encoded = serializeHcrAbiBundle([logic, a]);
	assert encoded.ok;
	const decoded = parseHcrAbiBundle(encoded.value);
	assert decoded.ok;
	assert decoded.value.length == 2;
	assert decoded.value[0].moduleId == "app";
	assert decoded.value[1].exports[0].signature == "func():int32";
}

test "HCR ABI bundle rejects duplicate modules" {
	const value = classifierTestManifest("windows-x64", "drc", "toolchain", [], []);
	const encoded = serializeHcrAbiBundle([value, value]);
	assert !encoded.ok;
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

function classifierTestManifest(
	targetKey: string,
	gcMode: string,
	toolchainKey: string,
	dependencies: string[],
	exports: HcrAbiExport[],
): HcrModuleAbi {
	const result = buildHcrModuleAbi("logic", targetKey, gcMode, toolchainKey, dependencies, exports);
	if (!result.ok) unreachable;
	return result.value;
}

test "HCR ABI body and dependency changes reload only the module" {
	const value = createHcrAbiExport("logic", "logic_value", "func():int32");
	const current = classifierTestManifest("windows-x64", "drc", "toolchain", ["std/io"], [value]);
	const body = classifierTestManifest("windows-x64", "drc", "toolchain", ["std/io"], [value]);
	const dependency = classifierTestManifest("windows-x64", "drc", "toolchain", ["std/io", "std/time"], [value]);
	const bodyDecision = classifyHcrReload(current, body);
	const dependencyDecision = classifyHcrReload(current, dependency);
	assert bodyDecision.kind == HcrReloadKind.ReloadModule;
	assert bodyDecision.reason == HcrReloadReason.ImplementationChanged;
	assert dependencyDecision.kind == HcrReloadKind.ReloadModule;
	assert dependencyDecision.reason == HcrReloadReason.DependenciesChanged;
}

test "HCR ABI signature and removal changes reload dependents" {
	const value32 = createHcrAbiExport("logic", "logic_value", "func():int32");
	const value64 = createHcrAbiExport("logic", "logic_value", "func():int64");
	const label = createHcrAbiExport("logic", "logic_label", "func():string");
	const current = classifierTestManifest("linux-x64", "orc", "toolchain", [], [value32, label]);
	const signature = classifierTestManifest("linux-x64", "orc", "toolchain", [], [value64, label]);
	const removed = classifierTestManifest("linux-x64", "orc", "toolchain", [], [value32]);
	const signatureDecision = classifyHcrReload(current, signature);
	const removedDecision = classifyHcrReload(current, removed);
	assert signatureDecision.kind == HcrReloadKind.ReloadDependents;
	assert signatureDecision.reason == HcrReloadReason.ExportSignatureChanged;
	assert signatureDecision.subject == value32.id;
	assert removedDecision.kind == HcrReloadKind.ReloadDependents;
	assert removedDecision.reason == HcrReloadReason.ExportRemoved;
	assert removedDecision.subject == label.id;
}

test "HCR ABI restart incompatibility wins over export changes" {
	const value32 = createHcrAbiExport("logic", "logic_value", "func():int32");
	const value64 = createHcrAbiExport("logic", "logic_value", "func():int64");
	const current = classifierTestManifest("windows-x64", "drc", "toolchain", [], [value32]);
	const candidate = classifierTestManifest("linux-x64", "drc", "toolchain", [], [value64]);
	const decision = classifyHcrReload(current, candidate);
	assert decision.kind == HcrReloadKind.RestartRequired;
	assert decision.reason == HcrReloadReason.TargetChanged;
	assert decision.subject == "windows-x64 -> linux-x64";
}
