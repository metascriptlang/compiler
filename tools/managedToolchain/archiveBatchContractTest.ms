import { batchArguments, WINDOWS_COMMAND_LINE_UNITS } from "./argumentBatches";
import { ArchiveMember, parseArchive } from "./archive";
import { createDirectoryExclusive } from "./nativePublication";
import {
	basename, copyFile, dirname, exists, isAbsolute, isExecutable,
	readFileBytes, remove, resolve, rmdir, writeFile,
} from "std/fs";
import { IoError } from "std/io/errors";
import { argv, cwd, execFileResult } from "std/process";

const SMALL_COUNT: int32 = 12;
const INITIAL_STRESS_COUNT: int32 = 256;
const SMALL_BUDGET: int32 = 1024;

let cases: int32 = 0;

function completed(result: Result<void, IoError>): void {
	if (!result.ok) { throw new Error(result.error.message); }
}

function expect(condition: boolean, message: string): void {
	if (!condition) { throw new Error(message); }
	cases += 1;
}

function bytes(path: string): Buffer {
	const read = readFileBytes(path);
	if (!read.ok) { throw new Error(read.error.message); }
	return read.value;
}

function members(path: string): ArchiveMember[] {
	const parsed = parseArchive(bytes(path));
	if (!parsed.ok) { throw new Error(path + ": " + parsed.error); }
	return parsed.value;
}

function invoke(executable: string, args: string[], directory: string): void {
	const done = execFileResult(executable, args, directory);
	if (!done.started || !done.pipeOk || done.exitCode != 0 ||
		done.signal != 0 || done.output != "" || done.errorOutput != "") {
		throw new Error(executable + " failed: started=" + String(done.started) +
			" errno=" + String(done.startErrno) + " exit=" + String(done.exitCode) +
			" signal=" + String(done.signal) + " stdout=" + done.output +
			" stderr=" + done.errorOutput);
	}
}

function invokeBatches(
	executable: string, prefix: string[], paths: string[], directory: string,
	limit: int32,
): int32 {
	const planned = batchArguments(executable, prefix, paths, limit);
	if (!planned.ok) { throw new Error(planned.error); }
	for (const batch of planned.value) {
		const args: string[] = [];
		for (const fixed of prefix) { args.push(fixed); }
		for (const path of batch) { args.push(path); }
		invoke(executable, args, directory);
	}
	return planned.value.length as int32;
}

function createArchive(
	ar: string, output: string, paths: string[], directory: string,
	limit: int32,
): int32 {
	if (exists(output)) { throw new Error("archive output already exists"); }
	if (paths.length == 0) {
		const emptyPlan = batchArguments(ar, ["rcsD", output], paths, limit);
		if (!emptyPlan.ok) { throw new Error(emptyPlan.error); }
		invoke(ar, ["rcsD", output], directory);
		return 1;
	}
	return invokeBatches(ar, ["rcsD", output], paths, directory, limit);
}

function memberName(index: int32): string {
	let serial = String(index);
	while (serial.length < 4) { serial = "0" + serial; }
	return serial + "-duplicate-original-member-name.o";
}

function stressCount(
	ar: string, strip: string, directory: string, output: string,
): int32 {
	let count = INITIAL_STRESS_COUNT;
	while (count <= 1024) {
		const paths: string[] = [];
		for (let i: int32 = 0; i < count; i += 1) {
			paths.push(directory + "/" + memberName(i));
		}
		const stripPlan = batchArguments(strip, ["--strip-debug"], paths);
		if (!stripPlan.ok) { throw new Error(stripPlan.error); }
		const arPlan = batchArguments(ar, ["rcsD", output], paths);
		if (!arPlan.ok) { throw new Error(arPlan.error); }
		if (stripPlan.value.length > 1 && arPlan.value.length > 1) { return count; }
		count *= 2;
	}
	throw new Error("stress paths do not exceed the Windows command budget");
}

function copyMembers(seed: string, directory: string, count: int32): string[] {
	completed(createDirectoryExclusive(directory));
	const paths: string[] = [];
	for (let i: int32 = 0; i < count; i += 1) {
		const path = directory + "/" + memberName(i);
		completed(copyFile(seed, path));
		paths.push(path);
	}
	return paths;
}

function checkMembers(path: string, count: int32, payload: Buffer): void {
	const entries = members(path);
	if (entries.length != count) { throw new Error("archive lost members"); }
	for (let i: int32 = 0; i < count; i += 1) {
		if (entries[i].name != memberName(i) ||
			Buffer.compare(entries[i].data, payload) != 0) {
			throw new Error("archive changed member " + String(i));
		}
	}
	cases += 1;
}

function emptyIndex(data: Buffer, at: int32, size: int32): boolean {
	if (at < 0 || at + 60 + size > data.length || data[at] != 47 ||
		data[at + 58] != 96 || data[at + 59] != 10) { return false; }
	for (let i: int32 = 1; i < 16; i += 1) {
		if (data[at + i] != 32) { return false; }
	}
	if (data[at + 48..at + 58].asString().trim() != String(size)) {
		return false;
	}
	for (let i: int32 = 0; i < size; i += 1) {
		if (data[at + 60 + i] != 0) { return false; }
	}
	return true;
}

function removeMembers(paths: string[], directory: string): void {
	for (const path of paths) { completed(remove(path)); }
	completed(rmdir(directory));
}

function run(): void {
	when (!windows) { throw new Error("this checks real Windows tool calls"); }
	if (argv.length != 4) {
		throw new Error("expected absolute clang, llvm-ar and llvm-strip paths");
	}
	const clang = argv[1];
	const ar = argv[2];
	const strip = argv[3];
	for (const tool of [clang, ar, strip]) {
		if (!isAbsolute(tool) || !isExecutable(tool)) {
			throw new Error("tool is not an absolute executable: " + tool);
		}
	}
	const parentCwd = cwd();
	const root = resolve(dirname(argv[0]) + "/" + basename(argv[0]) +
		" batch é日本🚀", parentCwd);
	completed(createDirectoryExclusive(root));
	const source = root + "/seed.c";
	const seed = root + "/seed.o";
	completed(writeFile(source, "int archiveSeed(void) { return 42; }\n"));
	invoke(clang, ["--no-default-config", "--target=x86_64-w64-mingw32",
		"-g", "-c", source, "-o", seed], root);
	const original = bytes(seed);
	const controlDir = root + "/control";
	const batchedDir = root + "/batched";
	const stressDir = root + "/stress";
	const stressArchive = root + "/stress.a";
	const count = stressCount(ar, strip, stressDir, stressArchive);
	const control = copyMembers(seed, controlDir, SMALL_COUNT);
	const batched = copyMembers(seed, batchedDir, SMALL_COUNT);
	const stress = copyMembers(seed, stressDir, count);
	const stripPrefix = ["--strip-debug"];
	const controlStrip = invokeBatches(strip, stripPrefix, control, root,
		WINDOWS_COMMAND_LINE_UNITS);
	const batchedStrip = invokeBatches(strip, stripPrefix, batched, root,
		SMALL_BUDGET);
	expect(controlStrip == 1 && batchedStrip > 1,
		"strip control or low-budget partition is wrong");
	const stripped = bytes(control[0]);
	expect(stripped.length < original.length,
		"debug stripping did not shrink the real object");
	for (let i: int32 = 0; i < SMALL_COUNT; i += 1) {
		if (Buffer.compare(bytes(control[i]), bytes(batched[i])) != 0) {
			throw new Error("bounded strip changed object " + String(i));
		}
	}
	cases += 1;
	const controlArchive = root + "/control.a";
	const batchedArchive = root + "/batched.a";
	const controlAr = createArchive(ar, controlArchive, control, root,
		WINDOWS_COMMAND_LINE_UNITS);
	const batchedAr = createArchive(ar, batchedArchive, batched, root,
		SMALL_BUDGET);
	expect(controlAr == 1 && batchedAr > 1,
		"ar control or low-budget partition is wrong");
	expect(Buffer.compare(bytes(controlArchive), bytes(batchedArchive)) == 0,
		"repeated rcsD differs from the single-call archive");
	checkMembers(batchedArchive, SMALL_COUNT, stripped);
	const stressStrip = invokeBatches(strip, stripPrefix, stress, root,
		WINDOWS_COMMAND_LINE_UNITS);
	const stressAr = createArchive(ar, stressArchive, stress, root,
		WINDOWS_COMMAND_LINE_UNITS);
	expect(stressStrip > 1 && stressAr > 1,
		"stress member list did not exceed the real Windows budget");
	checkMembers(stressArchive, count, stripped);
	const empty: string[] = [];
	expect(invokeBatches(strip, stripPrefix, empty, root,
		WINDOWS_COMMAND_LINE_UNITS) == 0, "empty archive called strip");
	const emptyArchive = root + "/empty.a";
	const emptyAr = createArchive(ar, emptyArchive, empty, root,
		WINDOWS_COMMAND_LINE_UNITS);
	const readerArgs = ["t", emptyArchive];
	const readerBudget = batchArguments(ar, readerArgs, empty,
		WINDOWS_COMMAND_LINE_UNITS);
	if (!readerBudget.ok) { throw new Error(readerBudget.error); }
	invoke(ar, readerArgs, root);
	const emptyBytes = bytes(emptyArchive);
	expect(emptyAr == 1 && members(emptyArchive).length == 0 &&
		emptyBytes.length == 140 && emptyIndex(emptyBytes, 8, 4) &&
		emptyIndex(emptyBytes, 72, 8),
		"empty COFF archive must have two zero-count indexes and no payloads");
	const evidence = resolve(argv[0] + ".empty.a", parentCwd);
	if (exists(evidence)) { throw new Error("empty archive evidence exists"); }
	completed(copyFile(emptyArchive, evidence));
	expect(cwd() == parentCwd, "external tools changed parent cwd");
	removeMembers(control, controlDir);
	removeMembers(batched, batchedDir);
	removeMembers(stress, stressDir);
	for (const path of [source, seed, controlArchive, batchedArchive,
		stressArchive, emptyArchive]) { completed(remove(path)); }
	completed(rmdir(root));
	expect(!exists(root), "successful fixture cleanup failed");
	console.log("archive batching: " + String(cases) + " cases OK");
}

when (!testBuild) { run(); }
