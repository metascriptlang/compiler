// std/os cpus(): each entry owns its model string, so dropping or keeping one array never frees another's.
// Axes: entries read independently, an array kept across the next call.
//
// @skip-js: std/os has no JS surface
// @skip-raiser: the raiser tier of std/os has no cpus
// @stdout: ok|ok|ok
// @exit: 0

import { cpus, cpuCount } from "std/os";

function sameModels(models: string[]): boolean {
	for (let i = 1; i < models.length; i++) {
		if (models[i] != models[0]) return false;
	}
	return models.length == cpuCount() && models[0].length > 0;
}

function modelsOf(): string[] {
	const found = cpus();
	const out: string[] = [];
	for (let i = 0; i < found.length; i++) out.push(found[i].model);
	return out;
}

const kept = cpus();
const first = kept.length == cpuCount() && kept[0].model.length > 0;
const second = sameModels(modelsOf());
const model = kept[0].model;
const third = sameModels(modelsOf()) && kept[kept.length - 1].model == model;
console.log(`${first ? "ok" : "bad"}|${second ? "ok" : "bad"}|${third ? "ok" : "bad"}`);
