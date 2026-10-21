// Parity program — each single-syscall std/fs mutation (mkdir, rmdir, remove, rename,
// symlink, chmod, writeFile, appendFile) and realpath on its success path and on every failure whose errno is the same on
// macOS and Linux, printed as the IoErrorKind the caller sees. Axes: missing path,
// missing parent, a file where a directory is expected, an existing target, an empty
// path, and four spawn workers failing while the main thread succeeds, so an error
// code read from the wrong thread or after a later call shows up as a wrong kind.
// Workdir derives from argv[0] so concurrent lane cells never collide.
//
// @xfail(raiser): every failure prints Other, the Raiser fs bridges store IoErrorKind+1 where index.rms expects an errno (inbox 2026-10-21-raiser-fs-errors-lose-their-kind.md)
// @stdout: mkdir new=ok again=ok missingParent=NotFound empty=NotFound
// @stdout: mkdir overFile=ok underFile=NotDirectory
// @stdout: rmdir missing=NotFound file=NotDirectory full=err empty=ok gone=false
// @stdout: remove missing=NotFound underFile=NotDirectory empty=NotFound
// @stdout: rename replace=ok content=A missing=NotFound intoMissing=NotFound
// @stdout: symlink new=ok read=A exists=AlreadyExists missingParent=NotFound remove=ok
// @stdout: chmod 755=ok x=true 644=ok x=false missing=NotFound
// @stdout: write new=ok append=ok content=xy missingParent=NotFound onDir=IsDirectory fullDevice=refused
// @stdout: realpath viaLink=same missing=empty
// @stdout: threads mainOk=2000 workerNotFound=8000
// @exit: 0

import { argv } from "std/process";
import {
	mkdir, rmdir, remove, rename, symlink, chmod, writeFile, readFile, removeAll,
	isDir, isExecutable, exists, appendFile, realpath, basename, dirname,
} from "std/fs";
import { IoError, IoErrorKind } from "std/io/errors";

function kindName(e: IoError): string {
	return match (e.kind) {
		IoErrorKind.NotFound => "NotFound",
		IoErrorKind.PermissionDenied => "PermissionDenied",
		IoErrorKind.AlreadyExists => "AlreadyExists",
		IoErrorKind.IsDirectory => "IsDirectory",
		IoErrorKind.NotDirectory => "NotDirectory",
		IoErrorKind.WriteFailed => "WriteFailed",
		_ => "Other",
	};
}

function show(r: Result<void, IoError>): string {
	return r.ok ? "ok" : kindName(r.error);
}

function failMkdirs(dir: string): number {
	let notFound = 0;
	for (let i = 0; i < 2000; i++) {
		const r = mkdir(`${dir}/missing/w${i}`);
		if (!r.ok && r.error.kind == IoErrorKind.NotFound) notFound += 1;
	}
	return notFound;
}

const dir = "/tmp/mscorpusFsSyscall-" + basename(dirname(argv[0])) + "-" + basename(argv[0]);
removeAll(dir);
const file = `${dir}/f.txt`;

console.log(`mkdir new=${show(mkdir(dir))} again=${show(mkdir(dir))} missingParent=${show(mkdir(`${dir}/no/sub`))} empty=${show(mkdir(""))}`);
writeFile(file, "x");
console.log(`mkdir overFile=${show(mkdir(file))} underFile=${show(mkdir(`${file}/sub`))}`);

mkdir(`${dir}/full`);
writeFile(`${dir}/full/x`, "x");
mkdir(`${dir}/empty`);
console.log(`rmdir missing=${show(rmdir(`${dir}/nope`))} file=${show(rmdir(file))} full=${rmdir(`${dir}/full`).ok ? "ok" : "err"} empty=${show(rmdir(`${dir}/empty`))} gone=${isDir(`${dir}/empty`)}`);

console.log(`remove missing=${show(remove(`${dir}/nope`))} underFile=${show(remove(`${file}/x`))} empty=${show(remove(""))}`);

writeFile(`${dir}/a`, "A");
writeFile(`${dir}/b`, "B");
const replaced = rename(`${dir}/a`, `${dir}/b`);
const after = readFile(`${dir}/b`);
console.log(`rename replace=${show(replaced)} content=${after.ok ? after.value : "?"} missing=${show(rename(`${dir}/nope`, `${dir}/c`))} intoMissing=${show(rename(`${dir}/b`, `${dir}/no/c`))}`);

const link = `${dir}/link`;
const made = symlink(`${dir}/b`, link);
const viaLink = readFile(link);
console.log(`symlink new=${show(made)} read=${viaLink.ok ? viaLink.value : "?"} exists=${show(symlink(`${dir}/b`, link))} missingParent=${show(symlink(`${dir}/b`, `${dir}/no/l`))} remove=${show(remove(link))}`);

const exe = chmod(file, 493);
const exeBit = isExecutable(file);
const plain = chmod(file, 420);
console.log(`chmod 755=${show(exe)} x=${exeBit} 644=${show(plain)} x=${isExecutable(file)} missing=${show(chmod(`${dir}/nope`, 420))}`);

const out = `${dir}/w.txt`;
const wrote = writeFile(out, "x");
const appended = appendFile(out, "y");
const written = readFile(out);
// Linux /dev/full fails the flush at fclose; macOS has no such device and passes trivially.
const fullDevice = !exists("/dev/full") || !writeFile("/dev/full", "x").ok;
console.log(`write new=${show(wrote)} append=${show(appended)} content=${written.ok ? written.value : "?"} missingParent=${show(writeFile(`${dir}/no/w.txt`, "x"))} onDir=${show(writeFile(dir, "x"))} fullDevice=${fullDevice ? "refused" : "accepted"}`);

symlink(out, `${dir}/wlink`);
console.log(`realpath viaLink=${realpath(`${dir}/wlink`) == realpath(out) && realpath(out) != "" ? "same" : "differs"} missing=${realpath(`${dir}/nope`) == "" ? "empty" : "?"}`);

const workers: Promise<number>[] = [];
for (let w = 0; w < 4; w++) workers.push(spawn(() => failMkdirs(dir)));
let mainOk = 0;
for (let i = 0; i < 2000; i++) {
	const sub = `${dir}/m${i}`;
	if (mkdir(sub).ok && rmdir(sub).ok) mainOk += 1;
}
let workerNotFound: number = 0;
for (const w of workers) workerNotFound += await w;
console.log(`threads mainOk=${mainOk} workerNotFound=${workerNotFound}`);

removeAll(dir);
