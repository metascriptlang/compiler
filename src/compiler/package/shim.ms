import { platform } from "std/process";

export const SHIM_MODE: int32 = 493;

export function shimFileName(cmd: string, targetOs: string = platform): string {
	return targetOs == "windows" ? `${cmd}.cmd` : cmd;
}

export function shimContent(pkg: string, cmd: string, targetOs: string = platform): string {
	if (targetOs == "windows") {
		return `@echo off\r\nmsc x ${pkg}:${cmd} %*\r\n`;
	}
	return `#!/bin/sh\nexec msc x '${pkg}:${cmd}' "$@"\n`;
}

export function isShim(content: string): boolean {
	return content.contains("msc x ");
}

test "a posix shim execs msc x with the qualified command" {
	const s = shimContent("greeter", "greet", "darwin");
	assert s.contains("exec msc x 'greeter:greet' \"$@\"");
	assert !s.contains("1.0.0");
	assert isShim(s);
}

test "a windows shim is a .cmd forwarding every argument" {
	assert shimFileName("greet", "windows") == "greet.cmd";
	const s = shimContent("greeter", "greet", "windows");
	assert s.contains("msc x greeter:greet %*");
	assert isShim(s);
}

test "a posix shim keeps the bare command name" {
	assert shimFileName("greet", "linux") == "greet";
}

test "a file that is not a shim is recognised as foreign" {
	assert !isShim("#!/bin/sh\necho hand written\n");
}
