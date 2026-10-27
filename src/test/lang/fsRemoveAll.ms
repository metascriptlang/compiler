import { ensureDir, exists, readDir, readFile, removeAll, symlink, writeFile } from "std/fs";

function scratch(name: string): string {
	const base = "/tmp/ms-removeAll-" + name + "-" + String(Math.floor(Math.random() * 1000000000));
	ensureDir(base + "/outside");
	writeFile(base + "/outside/victim.txt", "must survive");
	return base;
}

function victimSurvives(base: string): boolean {
	const content = try readFile(base + "/outside/victim.txt") catch "missing";
	return content == "must survive";
}

test "removeAll unlinks a child directory link without walking it" {
	const base = scratch("child");
	assert victimSurvives(base);
	assert ensureDir(base + "/tree").ok;
	assert symlink(base + "/outside", base + "/tree/link").ok;
	assert removeAll(base + "/tree").ok;
	assert !exists(base + "/tree");
	assert victimSurvives(base);
	assert removeAll(base).ok;
}

test "removeAll unlinks a directory link passed as the root" {
	const base = scratch("root");
	assert victimSurvives(base);
	assert symlink(base + "/outside", base + "/link").ok;
	assert removeAll(base + "/link").ok;
	assert !exists(base + "/link");
	assert readDir(base).length == 1;
	assert victimSurvives(base);
	assert removeAll(base).ok;
}

test "removeAll unlinks a directory link two levels deep" {
	const base = scratch("deep");
	assert victimSurvives(base);
	assert ensureDir(base + "/tree/a/b").ok;
	assert writeFile(base + "/tree/a/b/own.txt", "own").ok;
	assert symlink(base + "/outside", base + "/tree/a/b/link").ok;
	assert removeAll(base + "/tree").ok;
	assert !exists(base + "/tree");
	assert victimSurvives(base);
	assert removeAll(base).ok;
}

test "removeAll unlinks a dangling link as a child and as the root" {
	const base = scratch("dangling");
	assert victimSurvives(base);
	assert ensureDir(base + "/tree").ok;
	assert symlink(base + "/gone", base + "/tree/dangling").ok;
	assert symlink(base + "/gone", base + "/dangling").ok;
	assert removeAll(base + "/tree").ok;
	assert !exists(base + "/tree");
	assert removeAll(base + "/dangling").ok;
	assert readDir(base).length == 1;
	assert removeAll(base).ok;
	assert !exists(base);
}

test "removeAll of a missing path is ok" {
	assert removeAll("/tmp/ms-removeAll-missing-" + String(Math.floor(Math.random() * 1000000000))).ok;
}
