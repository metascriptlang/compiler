import { platform } from "std/process";

export const SHIM_MODE: int32 = 493;

const POSIX_MARKER = "# msc shim v1";
const WINDOWS_MARKER = "rem msc shim v1";

export function shimFileName(cmd: string, targetOs: string = platform): string {
	return targetOs == "windows" ? `${cmd}.cmd` : cmd;
}

export function shimContent(pkg: string, cmd: string, targetOs: string = platform): string {
	if (targetOs == "windows") {
		return `@echo off\r\n${WINDOWS_MARKER}\r\nmsc x ${pkg}:${cmd} %*\r\n`;
	}
	return `#!/bin/sh\n${POSIX_MARKER}\nexec msc x '${pkg}:${cmd}' "$@"\n`;
}

export function isShim(content: string): boolean {
	if (content.contains(POSIX_MARKER) || content.contains(WINDOWS_MARKER)) return true;
	return content.contains("exec msc x '") || (content.contains("msc x ") && content.contains("%*"));
}

test "a posix shim execs msc x with the qualified command" {
	const s = shimContent("greeter", "greet", "darwin");
	assert s.contains("exec msc x 'greeter:greet' \"$@\"");
	assert s.contains("# msc shim v1");
	assert !s.contains("1.0.0");
	assert isShim(s);
}

test "a windows shim is a .cmd forwarding every argument" {
	assert shimFileName("greet", "windows") == "greet.cmd";
	const s = shimContent("greeter", "greet", "windows");
	assert s.contains("msc x greeter:greet %*");
	assert s.contains("rem msc shim v1");
	assert isShim(s);
}

test "a posix shim keeps the bare command name" {
	assert shimFileName("greet", "linux") == "greet";
}

test "a file that is not a shim is recognised as foreign" {
	assert !isShim("#!/bin/sh\necho hand written\n");
	assert !isShim("#!/bin/sh\n# I sometimes run msc x by hand\necho hi\n");
}

test "a shim written before the marker exists is still recognised" {
	assert isShim("#!/bin/sh\nexec msc x 'greeter:greet' \"$@\"\n");
	assert isShim("@echo off\r\nmsc x greeter:greet %*\r\n");
}
