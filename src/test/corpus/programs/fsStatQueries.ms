// Parity program — the stat queries of std/fs (exists, isFile, isDir, fileSize, modifiedTime,
// changeStamp) on a file, an empty file, a directory, a symlink to each, a dangling symlink and a
// missing path. A symlink answers for its target, as stat does. changeStamp prints only what every
// backend shares: five fields with the size third, the same stamp for a path and its link, a new
// stamp after a rewrite, and "" for a missing path.
// Workdir derives from argv[0] so concurrent lane cells never collide.
//
// @stdout: file e=true f=true d=false size=5 time=true stamp=5:true
// @stdout: empty e=true f=true d=false size=0 time=true stamp=5:true
// @stdout: dir e=true f=false d=true size=true time=true stamp=5:true
// @stdout: linkFile e=true f=true d=false size=5 time=true stamp=5:true
// @stdout: linkDir e=true f=false d=true size=true time=true stamp=5:true
// @stdout: dangling e=false f=false d=false size=-1 time=false stamp=0:false
// @stdout: missing e=false f=false d=false size=-1 time=false stamp=0:false
// @stdout: stamp same=true linkSame=true rewritten=true
// @exit: 0

import { argv } from "std/process";
import {
	exists, isFile, isDir, fileSize, modifiedTime, changeStamp,
	writeFile, mkdir, symlink, removeAll, basename, dirname,
} from "std/fs";

function stampShape(path: string): string {
	const stamp = changeStamp(path);
	if (stamp == "") return "0:false";
	const fields = stamp.split(":");
	return `${fields.length}:${fields[2] == `${fileSize(path)}`}`;
}

function show(label: string, path: string): void {
	const size = fileSize(path);
	const sizeText = isDir(path) ? `${size >= 0}` : `${size}`;
	console.log(`${label} e=${exists(path)} f=${isFile(path)} d=${isDir(path)} size=${sizeText} time=${modifiedTime(path) > 0} stamp=${stampShape(path)}`);
}

const dir = "/tmp/mscorpusFsStat-" + basename(dirname(argv[0])) + "-" + basename(argv[0]);
removeAll(dir);
mkdir(dir);
writeFile(`${dir}/f`, "hello");
writeFile(`${dir}/e`, "");
mkdir(`${dir}/d`);
symlink(`${dir}/f`, `${dir}/lf`);
symlink(`${dir}/d`, `${dir}/ld`);
symlink(`${dir}/none`, `${dir}/dangling`);

show("file", `${dir}/f`);
show("empty", `${dir}/e`);
show("dir", `${dir}/d`);
show("linkFile", `${dir}/lf`);
show("linkDir", `${dir}/ld`);
show("dangling", `${dir}/dangling`);
show("missing", `${dir}/none`);

const before = changeStamp(`${dir}/f`);
const again = changeStamp(`${dir}/f`);
const viaLink = changeStamp(`${dir}/lf`);
writeFile(`${dir}/f`, "hello, world");
const after = changeStamp(`${dir}/f`);
console.log(`stamp same=${before == again} linkSame=${viaLink == before} rewritten=${after != before && after != ""}`);

removeAll(dir);
