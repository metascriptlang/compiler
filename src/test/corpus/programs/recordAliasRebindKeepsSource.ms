// @stdout: straight true cold true warm
// @stdout: branch false true cold true cold
// @stdout: branch true true cold true warm
// @stdout: selected false true cold true cold
// @stdout: selected true true cold true warm
// @stdout: repeat true,true,0,0,0,[cold],[] true,true,0,0,0,[cold],[]
// @stdout: copied true,true,0,0,0,[cold],[] true,true,0,0,0,[cold],[]
// @stdout: alias true,true,0,0,0,[cold],[] true,true,0,0,0,[cold],[]
// @stdout: alias copied true,true,0,0,0,[cold],[] true,true,0,0,0,[cold],[]
// @stdout: fresh copied true,true,0,0,0,[cold],[] true,true,0,0,0,[cold],[]
// @stdout: wrapped copied true,true,0,0,0,[cold],[] true,true,0,0,0,[cold],[]
// @stdout: actual false false true cold true cold
// @stdout: actual false true true cold true cold
// @stdout: actual true false true cold true cold
// @stdout: actual true true true cold true cold
// @exit: 0

import { execFileResult, ExecFileResult } from "std/process";

interface Status {
	started: boolean;
	pipeOk: boolean;
	exitCode: int32;
	signal: int32;
	output: string;
	errorOutput: string;
	startErrno: int32;
}

function made(text: string): Status {
	return { started: true, pipeOk: true, exitCode: 0, signal: 0,
		output: text, errorOutput: "", startErrno: 0 };
}

function show(label: string, a: Status, b: Status): void {
	console.log(label, a.started && a.pipeOk, a.output,
		b.started && b.pipeOk, b.output);
}

function straight(): void {
	const cold = made("cold");
	let other = cold;
	other = made("warm");
	show("straight", cold, other);
}

function branch(replace: boolean): void {
	const cold = made("cold");
	let other = cold;
	if (replace) other = made("warm");
	show(`branch ${replace}`, cold, other);
}

function selected(replace: boolean): void {
	try {
		const cold = made("cold");
		let other = cold;
		if (replace) other = made("warm");
		for (let i = 0; i < 2; i += 1) {
			const chosen = i == 1 ? other : cold;
			if (i == 1) show(`selected ${replace}`, cold, chosen);
		}
	} finally {
	}
}

function produced(args: string[], real: boolean): ExecFileResult {
	if (real) return execFileResult("node", args);
	return { started: true, pipeOk: true, exitCode: 0, signal: 0,
		output: "cold", errorOutput: "", startErrno: 0 };
}

function succeeded(r: ExecFileResult): boolean {
	return r.started && r.pipeOk && r.exitCode == 0 && r.signal == 0;
}

function both(r: ExecFileResult): string {
	return r.output + r.errorOutput;
}

function checked(where: string, warm: ExecFileResult, cold: ExecFileResult): void {
	if (!succeeded(warm) || !succeeded(cold)) {
		throw new Error(`${where}: cold ${cold.started} ${cold.pipeOk} ${both(cold)}`);
	}
	if (both(warm) != both(cold)) throw new Error(`${where}: output differs`);
}

function status(r: ExecFileResult): string {
	return `${r.started},${r.pipeOk},${r.exitCode},${r.signal},${r.startErrno},[${r.output}],[${r.errorOutput}]`;
}

function repeat(): void {
	const args = ["-e", "process.stdout.write('cold')"];
	const cold = execFileResult("node", args);
	const next = execFileResult("node", args);
	console.log("repeat", status(cold), status(next));
}

function copied(): void {
	const args = ["-e", "process.stdout.write('cold')"];
	const cold = execFileResult("node", args);
	const twoArgs = [...args];
	const next = execFileResult("node", twoArgs);
	console.log("copied", status(cold), status(next));
}

function aliased(): void {
	const args = ["-e", "process.stdout.write('cold')"];
	const cold = execFileResult("node", args);
	let next = cold;
	next = execFileResult("node", args);
	console.log("alias", status(cold), status(next));
}

function aliasedCopied(): void {
	const args = ["-e", "process.stdout.write('cold')"];
	const cold = execFileResult("node", args);
	const twoArgs = [...args];
	let next = cold;
	next = execFileResult("node", twoArgs);
	console.log("alias copied", status(cold), status(next));
}

function freshCopied(): void {
	const args = ["-e", "process.stdout.write('cold')"];
	const cold = execFileResult("node", args);
	const twoArgs = [...args];
	let next = produced(args, false);
	next = execFileResult("node", twoArgs);
	console.log("fresh copied", status(cold), status(next));
}

function wrappedCopied(): void {
	const args = ["-e", "process.stdout.write('cold')"];
	const cold = produced(args, true);
	const twoArgs = [...args];
	const next = produced(twoArgs, true);
	console.log("wrapped copied", status(cold), status(next));
}

function actual(real: boolean, replace: boolean): void {
	try {
		const args = ["-e", "process.stdout.write('cold')"];
		const cold = produced(args, real);
		const log = both(cold);
		if (!succeeded(cold) || log != "cold") throw new Error("initial cold failed");
		const coldTwoWork = "cold2";
		const twoArgs = [...args];
		let coldTwo = cold;
		if (replace) {
			coldTwo = produced(twoArgs, real);
			if (!succeeded(coldTwo)) throw new Error(`${coldTwoWork}: ${status(coldTwo)}`);
		}
		const writer = produced(args, real);
		for (let i = 0; i < 2; i += 1) {
			checked(`writer ${i}`, writer, i == 1 ? coldTwo : cold);
		}
		checked("reader", writer, cold);
		console.log(`actual ${real} ${replace}`, cold.started && cold.pipeOk,
			cold.output, coldTwo.started && coldTwo.pipeOk, coldTwo.output);
	} finally {
	}
}

straight();
branch(false);
branch(true);
selected(false);
selected(true);
repeat();
copied();
aliased();
aliasedCopied();
freshCopied();
wrappedCopied();
actual(false, false);
actual(false, true);
actual(true, false);
actual(true, true);
