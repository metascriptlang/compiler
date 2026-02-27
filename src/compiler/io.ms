// MetaScript Compiler CLI — File I/O helpers

import { exit, readFile, writeFile } from "std/process";

export function readSource(filePath: string): string {
	const source = readFile(filePath);
	if (source.length === 0) {
		console.log("Error: could not read file (or file is empty): " + filePath);
		exit(1);
	}
	return source;
}

export function writeOutput(filePath: string, content: string): void {
	const ok = writeFile(filePath, content);
	if (!ok) {
		console.log("Error: could not write file: " + filePath);
		exit(1);
	}
}
