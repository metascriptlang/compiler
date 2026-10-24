// Parity program — std/fs on names outside ASCII: create, write, stat, read, list, rename and
// delete a file named in ASCII, Vietnamese and CJK. The name reaches the filesystem as the UTF-8
// bytes the author wrote on every host, so readDir returns the same bytes it was given.
// Workdir derives from argv[0] so concurrent lane cells never collide.
//
// @stdout: ascii ok=true
// @stdout: báo cáo.txt ok=true
// @stdout: 日本.txt ok=true
// @stdout: dir [ascii.txt, báo cáo.txt, thư mục/, 日本.txt]
// @stdout: moved e=false moved=true
// @stdout: nested ok=true
// @stdout: left []
// @exit: 0

import { argv } from "std/process";
import {
	exists, isFile, fileSize, readFile, writeFile, readDir, rename, remove, mkdir, removeAll,
	basename, dirname,
} from "std/fs";

function cycle(dir: string, name: string): boolean {
	const path = `${dir}/${name}`;
	if (!writeFile(path, "xin chào").ok) return false;
	if (!exists(path) || !isFile(path) || fileSize(path) != 9) return false;
	const read = readFile(path);
	return read.ok && read.value == "xin chào";
}

const dir = "/tmp/mscorpusFsUnicode-" + basename(dirname(argv[0])) + "-" + basename(argv[0]);
removeAll(dir);
mkdir(dir);

for (const name of ["ascii.txt", "báo cáo.txt", "日本.txt"]) {
	console.log(`${name == "ascii.txt" ? "ascii" : name} ok=${cycle(dir, name)}`);
}
mkdir(`${dir}/thư mục`);
const names = readDir(dir);
names.sort();
console.log(`dir [${names.join(", ")}]`);

rename(`${dir}/báo cáo.txt`, `${dir}/日本.txt`);
console.log(`moved e=${exists(`${dir}/báo cáo.txt`)} moved=${readFile(`${dir}/日本.txt`).ok}`);

console.log(`nested ok=${cycle(`${dir}/thư mục`, "日本.txt")}`);
remove(`${dir}/thư mục/日本.txt`);
remove(`${dir}/日本.txt`);
remove(`${dir}/ascii.txt`);
removeAll(`${dir}/thư mục`);
console.log(`left [${readDir(dir).join(", ")}]`);
removeAll(dir);
