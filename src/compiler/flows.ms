// Flow recorder: with MSC_FLOWS=<file> set, a build appends one `msc<TAB>flow<TAB>metric<TAB>value`
// row per flow and metric (ms, instr, count) to that file. Call it from the main thread only.

import { env } from "std/process";
import { appendFile } from "std/fs";

extern function msCpuInstructions(): number;

export struct FlowStamp {
	ms: number;
	instr: number;
}

let flowsOn = env.get("MSC_FLOWS") != "";
let lapMs: number = 0;
let lapInstr: number = 0;
let haveInstr = true;
const flowNames: string[] = [];
const flowMs = new HashMap<string, number>();
const flowInstr = new HashMap<string, number>();
const flowCount = new HashMap<string, number>();

export function flowsEnabled(): boolean {
	return flowsOn;
}

export function flowsEnable(on: boolean): void {
	flowsOn = on;
	flowNames.length = 0;
	flowMs.clear();
	flowInstr.clear();
	flowCount.clear();
	haveInstr = true;
}

function flowAdd(name: string, ms: number, instr: number): void {
	if (!flowMs.has(name)) {
		flowNames.push(name);
		flowMs.set(name, 0);
		flowCount.set(name, 0);
	}
	flowMs.set(name, flowMs.get(name)! + ms);
	if (instr >= 0) flowInstr.set(name, (flowInstr.get(name) ?? 0) + instr);
	flowCount.set(name, flowCount.get(name)! + 1);
}

function readInstr(): number {
	const n = msCpuInstructions();
	if (n < 0) haveInstr = false;
	return n;
}

export function flowMark(): void {
	if (!flowsOn) return;
	lapMs = performance.now();
	lapInstr = readInstr();
}

export function flowLap(name: string): void {
	if (!flowsOn) return;
	const ms = performance.now();
	const instr = readInstr();
	flowAdd(name, ms - lapMs, instr - lapInstr);
	lapMs = performance.now();
	lapInstr = readInstr();
}

export function flowAddMs(name: string, ms: number): void {
	if (flowsOn) flowAdd(name, ms, -1);
}

export function flowStart(): FlowStamp {
	if (!flowsOn) return { ms: 0, instr: 0 };
	return { ms: performance.now(), instr: readInstr() };
}

export function flowStop(name: string, since: FlowStamp): void {
	if (!flowsOn) return;
	flowAdd(name, performance.now() - since.ms, readInstr() - since.instr);
}

export function flowRowsText(): string {
	let text = "";
	for (const name of flowNames) {
		text += `msc\t${name}\tms\t${flowMs.get(name)}\n`;
		if (haveInstr && flowInstr.has(name)) text += `msc\t${name}\tinstr\t${flowInstr.get(name)}\n`;
		text += `msc\t${name}\tcount\t${flowCount.get(name)}\n`;
	}
	return text;
}

export function flowsWrite(): void {
	if (!flowsOn) return;
	const file = env.get("MSC_FLOWS");
	if (file != "") appendFile(file, flowRowsText());
	flowsEnable(true);
}
