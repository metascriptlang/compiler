// The prelude pack's std stamp is a content key: a changed byte, an added file or a removed file
// in a sub-directory changes it, while rewriting identical bytes later does not.
import { writeFile, removeAll, ensureDir, remove } from "std/fs";
import { join, dirname } from "std/fs/path";
import { cwd } from "std/process";
import { hashContent } from "../../compiler/cache";
import { preludePackStamp } from "../../checker/preludePack";

function treeDir(tag: string): string {
	const dir = join(cwd(), `out/test/preludeStamp${tag}`);
	removeAll(dir);
	return dir;
}

function put(dir: string, rel: string, text: string): void {
	const path = join(dir, rel);
	ensureDir(dirname(path));
	const w = writeFile(path, text);
	if (!w.ok) throw new Error(`cannot write ${path}`);
}

function stampOf(tag: string, edit: (dir: string) => void): string {
	const dir = treeDir(tag);
	put(dir, "core/a.ms", "export const a = 1;\n");
	put(dir, "sub/deep/b.ms", "export const b = 2;\n");
	edit(dir);
	return preludePackStamp(dir);
}

test "hashContent is hashFarm in 16 hex digits then the byte length" {
	assert hashContent("") == "9ae16a3b2f90404f_0";
	assert hashContent("k999") == "798cbaac2a1c5e11_4";
}

test "one changed byte of one file changes the stamp" {
	const base = stampOf("Base", (dir) => {});
	const changed = stampOf("Byte", (dir) => put(dir, "sub/deep/b.ms", "export const b = 3;\n"));
	assert base != changed;
}

test "rewriting identical bytes later keeps the stamp" {
	const base = stampOf("Same", (dir) => {});
	const touched = stampOf("Touched", (dir) => put(dir, "core/a.ms", "export const a = 1;\n"));
	assert base == touched;
}

test "a file added or removed in a sub-directory changes the stamp" {
	const base = stampOf("Plain", (dir) => {});
	const added = stampOf("Added", (dir) => put(dir, "sub/deep/c.ms", ""));
	const removed = stampOf("Removed", (dir) => remove(join(dir, "sub/deep/b.ms")));
	assert base != added;
	assert base != removed;
	assert added != removed;
}
