import { argv } from "std/process";
import { readFile, writeFile, readDir, ensureDir, removeAll } from "std/fs";

function scratch(kind: string): string {
	return `/tmp/msPerfFsSmall-${kind}-${Date.now() % 1000000}`;
}

function payload(size: int32): string {
	return "x".repeat(size);
}

function once(kind: string, n: int32): int64 {
	const dir = scratch(kind);
	removeAll(dir);
	ensureDir(dir);
	let total: int64 = 0;
	if (kind == "write100" || kind == "write4k" || kind == "read100" || kind == "read4k") {
		const body = payload(kind.endsWith("100") ? 100 : 4096);
		const writes = kind.startsWith("write");
		if (writes) {
			for (let i: int32 = 0; i < n; i++) {
				if (!writeFile(`${dir}/f${i}`, body).ok) throw new Error("write failed");
			}
			total = n * body.length;
		} else {
			for (let i: int32 = 0; i < n; i++) writeFile(`${dir}/f${i}`, body);
			const files = n;
			for (let pass = 0; pass < 5; pass++) {
				for (let i: int32 = 0; i < files; i++) {
					const got = readFile(`${dir}/f${i}`);
					if (!got.ok) throw new Error("read failed");
					total += got.value.length;
				}
			}
		}
	} else if (kind == "readDir1000") {
		for (let i: int32 = 0; i < 1000; i++) writeFile(`${dir}/e${i}`, "");
		for (let i: int32 = 0; i < n; i++) total += readDir(dir).length;
	} else {
		removeAll(dir);
		throw new Error(`unknown case ${kind}`);
	}
	removeAll(dir);
	return total;
}

function run(kind: string, n: int32, reps: int32): int64 {
	let total: int64 = 0;
	for (let r: int32 = 0; r < reps; r++) total += once(kind, n);
	return total;
}

if (argv.length > 3) {
	const total = run(argv[1], argv[2].parseInt() as int32, argv[3].parseInt() as int32);
	console.log(`${argv[1]} ${argv[2]} ${total}`);
} else {
	let total: int64 = 0;
	total += run("write100", 3000, 1);
	total += run("write4k", 3000, 1);
	total += run("read100", 2000, 1);
	total += run("read4k", 2000, 1);
	total += run("readDir1000", 100, 1);
	console.log(`fsSmall ${total}`);
}
