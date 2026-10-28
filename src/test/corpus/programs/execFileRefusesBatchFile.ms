// @stdout: x.bat refused EINVAL
// @stdout: X.CMD refused EINVAL
// @stdout: x.bat. refused EINVAL
// @stdout: exec runs the batch file
// note: on Windows a .bat or .cmd runs through cmd.exe, which reparses the arguments with its own metacharacters, so execFileCapture and execFileResult refuse one with EINVAL as node's spawnSync does, whatever the extension's case or trailing dots; exec runs it through the shell. Before the fix C and Raiser passed `c&echo.PWNED` to cmd.exe and the injected command ran.
import { argv, env, exec, execFileCapture, execFileResult, execPath, platform, ProcessErrorKind } from "std/process";
import { removeAll, ensureDir, writeFile } from "std/fs";

const names = ["x.bat", "X.CMD", "x.bat."];

function cellKey(): int64 {
	const text = execPath + "|" + argv.join("|");
	let h: int64 = 0;
	for (let i = 0; i < text.length; i++) h = (h * 31 + (text.charCodeAt(i) as int64)) % 1000000007;
	return h;
}

if (platform == "windows") {
	const dir = `${env.get("TEMP")}\\msBatRefused${cellKey()}`;
	ensureDir(dir);
	writeFile(`${dir}\\x.bat`, "@echo arg=%1\r\n");
	writeFile(`${dir}\\X.CMD`, "@echo arg=%1\r\n");
	for (const name of names) {
		const path = `${dir}\\${name}`;
		let refused = true;
		for (const arg of ["c&echo.PWNED", "a b\"&echo.PWNED"]) {
			const r = execFileCapture(path, [arg]);
			refused = refused && !r.ok && r.error.kind == ProcessErrorKind.SpawnFailed && r.error.message == `spawnSync ${path} EINVAL`;
			const full = execFileResult(path, [arg]);
			refused = refused && !full.started && full.startErrno == 22 && !full.output.contains("PWNED");
		}
		console.log(refused ? `${name} refused EINVAL` : `${name} ran`);
	}
	const shell = exec(`"${dir}\\x.bat" c`);
	console.log(shell.ok && shell.value.contains("arg=c") ? "exec runs the batch file" : "exec failed");
	removeAll(dir);
} else {
	for (const name of names) console.log(`${name} refused EINVAL`);
	console.log("exec runs the batch file");
}
