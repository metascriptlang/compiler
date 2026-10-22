// Parity program — readFile of a file longer than a string can hold returns an IoError
// instead of ending the program. Sparse files from `dd seek` cost no disk: one just past
// the 2^31-1 length cap, one past 2^32 so a size truncated to 32 bits would look small,
// and a 3-byte file that must still read.
//
// @xfail(raiser): the message reads "I/O error (errno 9)", the Raiser fs bridges store IoErrorKind+1 where index.rms expects an errno (inbox 2026-10-21-raiser-fs-errors-lose-their-kind.md)
// @stdout: over2G=err kind=Unknown message=file too large
// @stdout: over4G=err kind=Unknown message=file too large
// @stdout: small=abc
// @exit: 0

import { argv, execFileResult } from "std/process";
import { readFile, writeFile, removeAll, mkdir, basename, dirname } from "std/fs";
import { IoErrorKind } from "std/io/errors";

const work = `${dirname(argv[0])}/${basename(argv[0])}.readFileTooLarge`;
removeAll(work);
mkdir(work);

function sparse(name: string, bytes: string): string {
	const path = `${work}/${name}`;
	const made = execFileResult("dd", ["if=/dev/zero", `of=${path}`, "bs=1", "count=0", `seek=${bytes}`]);
	if (made.exitCode != 0) console.log(`dd failed for ${name}: ${made.errorOutput}`);
	return path;
}

function probe(label: string, path: string): void {
	const r = readFile(path);
	if (r.ok) {
		console.log(`${label}=ok length=${r.value.length}`);
		return;
	}
	const kind = r.error.kind == IoErrorKind.Unknown ? "Unknown" : "other";
	const message = r.error.message.startsWith("file too large") ? "file too large" : r.error.message;
	console.log(`${label}=err kind=${kind} message=${message}`);
}

probe("over2G", sparse("over2G", "2147483648"));
probe("over4G", sparse("over4G", "4294967299"));
writeFile(`${work}/small`, "abc");
const small = readFile(`${work}/small`);
console.log(`small=${small.ok ? small.value : "err"}`);
removeAll(work);
