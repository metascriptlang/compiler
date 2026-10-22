// Parity program — the std/fs operations round-trip a path that holds non-ASCII UTF-8
// (Vietnamese and CJK) and answer its failures with the same IoErrorKind on every host,
// Windows included: the output holds only what POSIX and Windows share, so a path encoded
// differently by one call than by the next, or an error code mapped differently, shows up
// as a wrong line. Workdir sits beside argv[0] so concurrent lane cells never collide.
//
// @stdout: mkdir new=ok again=ok isDir=true exists=true
// @stdout: write ok=true append=ok read=xin chào 日本 size=16 isFile=true
// @stdout: stat time=true stamp=true exec=true realpath=true
// @stdout: readDir dữ liệu/,tệp-日本.txt
// @stdout: rename ok=ok from=false to=true content=abc
// @stdout: errors readMissing=NotFound writeMissingParent=NotFound mkdirMissingParent=NotFound
// @stdout: errors removeMissing=NotFound rmdirMissing=NotFound renameMissing=NotFound rmdirFull=err
// @stdout: remove file=ok inner=ok rmdir=ok gone=false
// @stdout: removeAll ok=true exists=false
// @exit: 0

import { argv } from "std/process";
import {
	mkdir, rmdir, remove, rename, writeFile, appendFile, readFile, readDir, removeAll, chmod,
	exists, isDir, isFile, isExecutable, fileSize, modifiedTime, changeStamp, realpath,
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

function readShow(path: string): string {
	const r = readFile(path);
	return r.ok ? r.value : kindName(r.error);
}

const root = argv[0] + ".fsPathRoundTrip";
removeAll(root);
mkdir(root);
const dir = `${root}/dữ liệu`;
const file = `${root}/tệp-日本.txt`;

console.log(`mkdir new=${show(mkdir(dir))} again=${show(mkdir(dir))} isDir=${isDir(dir)} exists=${exists(dir)}`);

const wrote = writeFile(file, "xin chào");
const appended = appendFile(file, " 日本");
console.log(`write ok=${wrote.ok} append=${show(appended)} read=${readShow(file)} size=${fileSize(file)} isFile=${isFile(file)}`);

chmod(file, 493);
console.log(`stat time=${modifiedTime(file) > 0} stamp=${changeStamp(file) != ""} exec=${isExecutable(file)} realpath=${realpath(file).endsWith("tệp-日本.txt")}`);

const names = readDir(root);
names.sort();
console.log(`readDir ${names.join(",")}`);

const plain = `${root}/plain.txt`;
const moved = `${root}/moved.txt`;
writeFile(plain, "abc");
const renamed = rename(plain, moved);
console.log(`rename ok=${show(renamed)} from=${exists(plain)} to=${isFile(moved)} content=${readShow(moved)}`);

const inner = `${dir}/trong.txt`;
writeFile(inner, "x");

console.log(`errors readMissing=${readShow(`${root}/nope`)} writeMissingParent=${show(writeFile(`${root}/no/f`, "x"))} mkdirMissingParent=${show(mkdir(`${root}/no/sub`))}`);
console.log(`errors removeMissing=${show(remove(`${root}/nope`))} rmdirMissing=${show(rmdir(`${root}/nope`))} renameMissing=${show(rename(`${root}/nope`, `${root}/c`))} rmdirFull=${rmdir(dir).ok ? "ok" : "err"}`);

console.log(`remove file=${show(remove(file))} inner=${show(remove(inner))} rmdir=${show(rmdir(dir))} gone=${exists(dir)}`);

console.log(`removeAll ok=${removeAll(root).ok} exists=${exists(root)}`);
