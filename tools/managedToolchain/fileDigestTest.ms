import { ensureDir, exists, remove, rmdir, writeFileBytes } from "std/fs";
import { sha256File } from "./fileDigest";

const OUTPUT_DIRECTORY = "out/fileDigestTest";
let cases: int32 = 0;

function expectHash(path: string, bytes: Buffer, expected: string): void {
	const written = writeFileBytes(path, bytes);
	if (!written.ok) { throw new Error(written.error.message); }
	const digest = sha256File(path);
	if (!digest.ok) { throw new Error(digest.error); }
	if (digest.value != expected) {
		throw new Error("file SHA-256 differs: " + path);
	}
	cases += 1;
}

function run(): void {
	if (exists(OUTPUT_DIRECTORY)) {
		throw new Error("test output already exists: " + OUTPUT_DIRECTORY);
	}
	const created = ensureDir(OUTPUT_DIRECTORY);
	if (!created.ok) { throw new Error(created.error.message); }
	const path = OUTPUT_DIRECTORY + "/binary with spaces.bin";
	expectHash(path, [0, 255, 195, 40, 0, 128, 10, 13, 127],
		"02b82d4168ea1f7943df65fa7ff22891cc57a93b7c5e15e1b71a3f7ae43f3324");
	const allBytes = Buffer.alloc(256);
	for (let i: int32 = 0; i < 256; i += 1) { allBytes[i] = i as uint8; }
	expectHash(path, allBytes,
		"40aff2e9d2d8922e47afd4648e6967497158785fbd1da870e7110266bf944880");
	expectHash(path, Buffer.alloc(0),
		"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
	expectHash(path, Buffer.fromString("abc", "utf8"),
		"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
	const absent = OUTPUT_DIRECTORY + "/absent";
	const missing = sha256File(absent);
	if (missing.ok || !missing.error.startsWith("cannot read " + absent + ": ")) {
		throw new Error("missing file was not refused with its path");
	}
	cases += 1;
	const removed = remove(path);
	if (!removed.ok) { throw new Error(removed.error.message); }
	const directoryRemoved = rmdir(OUTPUT_DIRECTORY);
	if (!directoryRemoved.ok) { throw new Error(directoryRemoved.error.message); }
	console.log("file SHA-256: " + String(cases) + " cases OK");
}

when (!testBuild) { run(); }
