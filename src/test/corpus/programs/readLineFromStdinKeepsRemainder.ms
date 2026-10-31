// @xfail(raiser): spawn(argv[0]) fails on the Raiser VM; card 2026-10-27-raiser-argv0-is-the-script-so-a-self-spawn-fails
// @stdout: 3:one|3:two|0:|5:café|5:tail\r|0:|0:
// @stdout: 0:|0:|0:|0:|0:|0:|0:
// std/io readLine reads successive lines of stdin on every backend: LF and CRLF end a line, the bytes after the last LF form one more line kept whole, and end of input reads "", also when the input is empty from the start.
import { argv, execPath, exec, exit } from "std/process";
import { readLine } from "std/io";
import { writeFile, remove } from "std/fs";

if (argv.length > 1 && argv[1] == "child") {
	const parts: string[] = [];
	for (let i = 0; i < 7; i++) {
		const line = readLine();
		parts.push(`${line.byteLength()}:${line.replace("\r", "\\r")}`);
	}
	console.log(parts.join("|"));
	exit(0);
}

const path = `readLineFromStdin-${argv[0].split("/").slice(-2).join("-")}.txt`;
writeFile(path, "one\r\ntwo\n\ncafé\ntail\r");
const self = argv[0].endsWith("js") ? `${execPath} ${argv[0]}` : argv[0];
const r = exec(`${self} child < ${path}`);
remove(path);
if (!r.ok) {
	console.log(`child failed: ${r.error.message}`);
	exit(1);
}
console.log(r.value.trim());

writeFile(path, "");
const empty = exec(`${self} child < ${path}`);
remove(path);
if (!empty.ok) {
	console.log(`child failed on empty input: ${empty.error.message}`);
	exit(1);
}
console.log(empty.value.trim());
