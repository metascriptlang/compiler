// @xfail(raiser): spawn(argv[0]) fails on the Raiser VM; card 2026-10-27-raiser-argv0-is-the-script-so-a-self-spawn-fails
// @stdout: 4:abcd|4:efgh|2:ij|0:|0:
// @stdout: line ab|5:cdefg|0:
// std/io readBytes reads stdin in chunks of at most n bytes on every backend, returning fewer at the end of input and none after it, and shares one buffer with readLine.
import { argv, execPath, exec, exit } from "std/process";
import { readBytes, readLine } from "std/io";
import { writeFile, remove } from "std/fs";

function text(b: uint8[]): string {
	let s = "";
	for (const c of b) s += String.fromCharCode(c);
	return s;
}

if (argv.length > 2 && argv[1] == "child") {
	const parts: string[] = [];
	if (argv[2] == "mixed") {
		parts.push(`line ${readLine()}`);
		const rest = readBytes(10);
		parts.push(`${rest.length}:${text(rest)}`);
		parts.push(`${readBytes(10).length}:`);
	} else {
		for (let i = 0; i < 5; i++) {
			const chunk = readBytes(4);
			parts.push(`${chunk.length}:${text(chunk)}`);
		}
	}
	console.log(parts.join("|"));
	exit(0);
}

const path = `readBytesFromStdin-${argv[0].replaceAll("\\", "/").split("/").slice(-2).join("-")}.txt`;
const self = argv[0].endsWith("js") ? `${execPath} ${argv[0]}` : argv[0];
writeFile(path, "abcdefghij");
const chunks = exec(`${self} child chunks < ${path}`);
writeFile(path, "ab\ncdefg");
const mixed = exec(`${self} child mixed < ${path}`);
remove(path);
if (!chunks.ok || !mixed.ok) {
	console.log("child failed");
	exit(1);
}
console.log(chunks.value.trim());
console.log(mixed.value.trim());
