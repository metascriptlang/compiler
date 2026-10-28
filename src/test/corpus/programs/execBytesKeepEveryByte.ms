// Parity program — execBytes and execFileCaptureBytes return exactly the bytes the child wrote
// on stdout, ill-formed UTF-8 and NUL included, the same on C and JS. The text readers decode
// the same output, so the two views differ only where the bytes are not valid text.
//
// @stdout: execBytes length=5 61,ff,62,0,63
// @stdout: execFileCaptureBytes length=4 e2,82,c3,28
// @stdout: text of the same output length=3 e2,82,c3,28 -> fffd,fffd,28
// @stdout: failure kind=NonZeroExit code=3 output=78,fffd
// @skip-raiser: the byte readers return Buffer, which the Raiser tier has no type for
// @exit: 0

import { execBytes, execFileCapture, execFileCaptureBytes, platform, ProcessErrorKind } from "std/process";

const shell = platform == "windows" ? "sh" : "/bin/sh";

function hex(bytes: Buffer): string {
	const out: string[] = [];
	for (let i = 0; i < bytes.length; i++) out.push(bytes[i].toString(16));
	return out.join(",");
}

function units(text: string): string {
	const out: string[] = [];
	for (let i = 0; i < text.length; i++) out.push(text.charCodeAt(i).toString(16));
	return out.join(",");
}

const viaShell = execBytes(`${shell} -c "printf 'a\\377b\\000c'"`);
console.log(viaShell.ok ? `execBytes length=${viaShell.value.length} ${hex(viaShell.value)}` : "execBytes err");

const cut = ["-c", "printf '\\342\\202\\303('"];
const direct = execFileCaptureBytes(shell, cut);
console.log(direct.ok ? `execFileCaptureBytes length=${direct.value.length} ${hex(direct.value)}` : "execFileCaptureBytes err");

const text = execFileCapture(shell, cut);
console.log(text.ok ? `text of the same output length=${text.value.length} ${direct.ok ? hex(direct.value) : ""} -> ${units(text.value)}` : "text err");

const failed = execFileCaptureBytes(shell, ["-c", "printf 'x\\377'; exit 3"]);
console.log(failed.ok ? "failure ok" : `failure kind=${failed.error.kind == ProcessErrorKind.NonZeroExit ? "NonZeroExit" : "other"} code=${failed.error.exitCode} output=${units(failed.error.output)}`);
