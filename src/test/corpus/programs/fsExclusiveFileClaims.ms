// Parity program — std/fs writeFileExclusive and copyFileExclusive report an existing path as
// AlreadyExists and leave its content, and five threads claiming the same 200 names by each
// win every name exactly once.
//
// @stdout: writeFileExclusive new=ok again=AlreadyExists kept=one missingParent=NotFound
// @stdout: copyFileExclusive new=ok copied=one again=AlreadyExists kept=one missingSource=NotFound
// @stdout: claims names=200 written=200 copied=200
// @exit: 0
import { argv } from "std/process";
import { mkdir, writeFile, readFile, writeFileExclusive, copyFileExclusive, removeAll, basename, dirname } from "std/fs";
import { IoError, IoErrorKind } from "std/io/errors";

function show(r: Result<void, IoError>): string {
	if (r.ok) return "ok";
	return match (r.error.kind) {
		IoErrorKind.NotFound => "NotFound",
		IoErrorKind.AlreadyExists => "AlreadyExists",
		_ => "Other",
	};
}

function text(path: string): string {
	return try readFile(path) catch "";
}

function writeAll(dir: string): number {
	let won = 0;
	for (let i = 0; i < 200; i++) {
		if (writeFileExclusive(`${dir}/written/p${i}`, "w").ok) won += 1;
	}
	return won;
}

function copyAll(dir: string): number {
	let won = 0;
	for (let i = 0; i < 200; i++) {
		if (copyFileExclusive(`${dir}/a.txt`, `${dir}/copied/p${i}`).ok) won += 1;
	}
	return won;
}

const dir = "/tmp/mscorpusExclusiveFile-" + basename(dirname(argv[0])) + "-" + basename(argv[0]);
removeAll(dir);
mkdir(dir);
const made = writeFileExclusive(`${dir}/a.txt`, "one");
const again = writeFileExclusive(`${dir}/a.txt`, "two");
console.log(`writeFileExclusive new=${show(made)} again=${show(again)} kept=${text(`${dir}/a.txt`)} missingParent=${show(writeFileExclusive(`${dir}/no/f.txt`, "x"))}`);

const copied = copyFileExclusive(`${dir}/a.txt`, `${dir}/b.txt`);
writeFile(`${dir}/c.txt`, "three");
const copiedAgain = copyFileExclusive(`${dir}/c.txt`, `${dir}/b.txt`);
console.log(`copyFileExclusive new=${show(copied)} copied=${text(`${dir}/b.txt`)} again=${show(copiedAgain)} kept=${text(`${dir}/b.txt`)} missingSource=${show(copyFileExclusive(`${dir}/none.txt`, `${dir}/d.txt`))}`);

mkdir(`${dir}/written`);
mkdir(`${dir}/copied`);
const writers: Promise<number>[] = [];
const copiers: Promise<number>[] = [];
for (let w = 0; w < 4; w++) {
	writers.push(spawn(() => writeAll(dir)));
	copiers.push(spawn(() => copyAll(dir)));
}
let written = writeAll(dir);
let copies = copyAll(dir);
for (const w of writers) written += await w;
for (const c of copiers) copies += await c;
console.log(`claims names=200 written=${written} copied=${copies}`);

removeAll(dir);
