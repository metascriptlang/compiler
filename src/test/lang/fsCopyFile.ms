import { copyFile, ensureDir, exists, modifiedTime, readFile, readFileBytes, removeAll, writeFile, writeFileBytes } from "std/fs";
import { execFileCapture } from "std/process";
import { Buffer } from "std/core/buffer";

function scratch(name: string): string {
	const base = "/tmp/ms-copyFile-" + name + "-" + String(Math.floor(Math.random() * 1000000000));
	ensureDir(base);
	return base;
}

function hexOf(path: string): string {
	const bytes = try readFileBytes(path) catch Buffer.fromArray([]);
	return bytes.toHex();
}

test "copyFile copies every byte of a file that is not UTF-8 text" {
	for (const size of [0, 1, 4097, 70000]) {
		const base = scratch("bytes");
		const data: number[] = [];
		for (let i = 0; i < size; i += 1) data.push((i * 7) % 256);
		assert writeFileBytes(base + "/src.bin", Buffer.fromArray(data)).ok;
		assert copyFile(base + "/src.bin", base + "/dst.bin").ok;
		assert hexOf(base + "/dst.bin") == hexOf(base + "/src.bin"), `size ${size}`;
		assert hexOf(base + "/dst.bin").length == size * 2, `size ${size}`;
		assert removeAll(base).ok;
	}
}

test "copyFile over a longer existing file leaves exactly the source's bytes" {
	const base = scratch("over");
	assert writeFile(base + "/src.txt", "short").ok;
	assert writeFile(base + "/dst.txt", "a much longer previous content").ok;
	assert copyFile(base + "/src.txt", base + "/dst.txt").ok;
	assert (try readFile(base + "/dst.txt") catch "") == "short";
	assert removeAll(base).ok;
}

test "writing the copy leaves the source unchanged, and writing the source leaves the copy" {
	const base = scratch("apart");
	assert writeFile(base + "/src.txt", "original").ok;
	assert copyFile(base + "/src.txt", base + "/dst.txt").ok;
	assert writeFile(base + "/dst.txt", "changed copy").ok;
	assert (try readFile(base + "/src.txt") catch "") == "original";
	assert writeFile(base + "/src.txt", "changed source").ok;
	assert (try readFile(base + "/dst.txt") catch "") == "changed copy";
	assert removeAll(base).ok;
}

test "copyFile of a missing source fails and creates no destination" {
	const base = scratch("missing");
	assert !copyFile(base + "/absent.txt", base + "/dst.txt").ok;
	assert !exists(base + "/dst.txt");
	assert removeAll(base).ok;
}

test "a copy is modified when it is made, not when its source was, whether or not the destination existed" {
	const base = scratch("mtime");
	assert writeFile(base + "/src.txt", "aged").ok;
	assert execFileCapture("touch", ["-t", "200001010000", base + "/src.txt"]).ok;
	assert writeFile(base + "/old.txt", "previous").ok;
	for (const dst of [base + "/new.txt", base + "/old.txt"]) {
		assert copyFile(base + "/src.txt", dst).ok;
		assert (try readFile(dst) catch "") == "aged";
		assert modifiedTime(dst) > modifiedTime(base + "/src.txt") + 86400, dst;
	}
	assert removeAll(base).ok;
}
