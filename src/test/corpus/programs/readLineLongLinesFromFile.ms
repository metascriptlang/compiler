// @xfail(raiser): spawn(argv[0]) fails on the Raiser VM (a self-spawn probe prints "spawn failed" on main too); card 2026-10-27-raiser-argv0-is-the-script-so-a-self-spawn-fails
// @stdout: 5000 0 600 4
// @skip-js: the child reads a real stdin through spawn, which the JS lane does not run
// std/io readLine takes a line longer than its stack chunk through getline (`char **`, `size_t *`).
// The parent reads a file of such lines and feeds it to a child of itself, whose lengths it prints.

import { spawn, ChildStream, argv, exit } from "std/process";
import { readLine } from "std/io";
import { readFile, writeFile, remove } from "std/fs";

if (argv.length > 1 && argv[1] == "child") {
	for (let i = 0; i < 4; i++) console.log(readLine().byteLength());
	exit(0);
}

const path = `readLineLongLines-${argv[0].split("/").slice(-2).join("-")}.txt`;
const lines = ["x".repeat(5000), "", "y".repeat(600) + "\r", "tail"];
writeFile(path, lines.join("\n") + "\n");
const data = readFile(path);
remove(path);
if (!data.ok) {
	console.log("read failed");
	exit(1);
}

const started = spawn(argv[0], ["child"]);
if (!started.ok) {
	console.log("spawn failed");
	exit(1);
}
const child = started.value;
child.write(data.value, 5000);
child.closeStdin();
let text = "";
while (true) {
	const got = child.read(ChildStream.Stdout, 5000);
	if (!got.ok || got.value.ended) break;
	text += got.value.data;
}
child.wait(5000);
child.close();
console.log(text.trim().replaceAll("\n", " "));
if (text.trim() != "5000\n0\n600\n4") exit(1);
