// Every generated module includes runtime/core/system.h, so whatever it reaches is parsed by every C compile.

import { exists, readFile } from "std/fs";
import { dirname, join, normalize, relative } from "std/fs/path";
import { resolveRuntimeDir } from "../../utils/path";

const WINDOWS_SDK_HEADERS = ["windows.h", "winsock.h", "winsock2.h", "ws2tcpip.h", "mswsock.h", "bcrypt.h"];

function quotedTarget(root: string, from: string, name: string): string {
	for (const base of [root, dirname(from)]) {
		const path = normalize(join(base, name));
		if (exists(path)) return path;
	}
	return "";
}

function windowsSdkIncludesReachedFrom(root: string, start: string): string[] {
	const seen = new HashSet<string>();
	const pending: string[] = [start];
	const found: string[] = [];
	while (pending.length > 0) {
		const path = pending.pop()!;
		if (seen.has(path)) continue;
		seen.add(path);
		const lines = (try readFile(path) catch "").split("\n");
		for (let i = 0; i < lines.length; i++) {
			const line = lines[i].trim();
			if (!line.startsWith("#")) continue;
			const directive = line.slice(1, line.length).trim();
			if (!directive.startsWith("include")) continue;
			const spec = directive.slice(7, directive.length).trim();
			if (spec.startsWith("<")) {
				const name = spec.slice(1, spec.indexOf(">"));
				if (WINDOWS_SDK_HEADERS.includes(name.toLowerCase())) found.push(`${relative(root, path)}:${i + 1} <${name}>`);
			} else if (spec.startsWith("\"")) {
				const target = quotedTarget(root, path, spec.slice(1, spec.indexOf("\"", 1)));
				if (target != "") pending.push(target);
			}
		}
	}
	return found;
}

test "the header every generated module includes reaches no Windows SDK header" {
	const root = resolveRuntimeDir();
	const start = join(root, "runtime/core/system.h");
	assert exists(start);
	assert windowsSdkIncludesReachedFrom(root, start).join(", ") == "";
}

test "the closure scan follows quoted includes to a Windows SDK header" {
	const root = resolveRuntimeDir();
	assert windowsSdkIncludesReachedFrom(root, join(root, "runtime/process.h")).length > 0;
}
