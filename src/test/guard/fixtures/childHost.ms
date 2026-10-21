import { execFileResult, platform } from "std/process";

export const onWindows = platform == "windows";

export function host(name: string): string {
	return onWindows ? name : `/bin/${name}`;
}

export function listed(pid: string): string {
	if (onWindows) {
		const out = execFileResult("tasklist", ["/FI", `PID eq ${pid}`, "/NH", "/FO", "CSV"]).output;
		return out.contains(`","${pid}",`) ? "running" : "";
	}
	return execFileResult("/bin/ps", ["-o", "stat=", "-p", pid]).output.trim();
}

export function forceKill(pid: string): void {
	if (onWindows) execFileResult("taskkill", ["/F", "/PID", pid]);
	else execFileResult("/bin/kill", ["-9", pid]);
}
