import { ensureHostTableLoaded, _resetBridgeStateForTests } from "../../compiler/meta/hostTable";
import { lookupHostFn, _resetHostRegistryForTests } from "../../raiser/hostRegistry";
import { raiserString, raiserInt, RaiserValueKind } from "../../raiser/value";
import { exists, isDir, readFile, writeFile, removeAll, join } from "std/fs";
import { env } from "std/process";

function comptimeTempDir(): string {
	const t = env.get("TMP");
	if (t != "") return t;
	const t2 = env.get("TEMP");
	if (t2 != "") return t2;
	const t3 = env.get("TMPDIR");
	if (t3 != "") return t3;
	return "/tmp";
}

function freshComptimePath(name: string): string {
	const p = join(comptimeTempDir(), name);
	removeAll(p);
	return p;
}

function prepareComptimeHost(): void {
	_resetHostRegistryForTests();
	_resetBridgeStateForTests();
	ensureHostTableLoaded();
}

test "comptime host effects: mkdir return code agrees with filesystem and errno" {
	prepareComptimeHost();
	const path = freshComptimePath("msc-comptime-mkdir-contract");
	const mkdirFn = lookupHostFn("msFsMkdir");
	const errno = lookupHostFn("msFsLastErrno");
	const result = mkdirFn([raiserString(path)]);
	assert result.kind == RaiserValueKind.Int;
	assert result.intVal == 1;
	assert errno([]).intVal == 0;
	assert exists(path) && isDir(path);
	removeAll(path);
	const missing = join(path, "absent/child");
	const refused = mkdirFn([raiserString(missing)]);
	assert refused.kind == RaiserValueKind.Int;
	assert refused.intVal == 0;
	assert errno([]).intVal != 0;
	assert !exists(missing);
}

test "comptime host effects: append and replace modes produce their promised bytes" {
	prepareComptimeHost();
	const path = freshComptimePath("msc-comptime-write-contract.txt");
	const writeFn = lookupHostFn("msFsWriteFileMode");
	const errno = lookupHostFn("msFsLastErrno");
	const cases = [
		{ mode: "wb", input: "aa", expected: "aa" },
		{ mode: "ab", input: "bb", expected: "aabb" },
		{ mode: "wb", input: "c", expected: "c" },
	];
	for (const item of cases) {
		const result = writeFn([raiserString(path), raiserString(item.input), raiserString(item.mode)]);
		assert result.kind == RaiserValueKind.Int;
		assert result.intVal == 1, item.mode;
		assert errno([]).intVal == 0, item.mode;
		const back = readFile(path);
		assert back.ok;
		assert back.value == item.expected, item.mode;
	}
	const chmodFn = lookupHostFn("msFsChmod");
	assert chmodFn != null;
	const changed = chmodFn([raiserString(path), raiserInt(420)]);
	assert changed.kind == RaiserValueKind.Int;
	assert changed.intVal == 1;
	removeAll(path);
	const executable = lookupHostFn("msFsIsExecutable");
	assert executable != null;
	const missing = executable([raiserString(path)]);
	assert missing.kind == RaiserValueKind.Int;
	assert missing.intVal == 0;
}
