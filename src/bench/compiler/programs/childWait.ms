import { argv } from "std/process";
import { spawn } from "std/process/child";

function once(kind: string, n: int32): int64 {
	let total: int64 = 0;
	for (let i: int32 = 0; i < n; i++) {
		const started = kind == "exit0" ? spawn("/bin/sh", ["-c", "exit 3"]) : spawn("/bin/sh", ["-c", "sleep 0.03; exit 3"]);
		if (!started.ok) throw new Error("spawn failed");
		const child = started.value;
		const status = child.wait(5000);
		if (!status.ok) throw new Error("wait failed");
		total += status.value.code;
		child.close();
	}
	return total;
}

function run(kind: string, n: int32, reps: int32): int64 {
	if (kind != "exit0" && kind != "sleep30") throw new Error(`unknown case ${kind}`);
	let total: int64 = 0;
	for (let r: int32 = 0; r < reps; r++) total += once(kind, n);
	return total;
}

if (argv.length > 3) {
	const total = run(argv[1], argv[2].parseInt() as int32, argv[3].parseInt() as int32);
	console.log(`${argv[1]} ${argv[2]} ${total}`);
} else {
	const total = run("exit0", 300, 1) + run("sleep30", 10, 1);
	console.log(`childWait ${total}`);
}
