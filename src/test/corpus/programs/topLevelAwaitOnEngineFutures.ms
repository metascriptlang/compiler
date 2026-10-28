// @stdout: top-level nextChanges names churn.ms: true
// @stdout: inside an async function: true
// @exit: 0
// @skip-js: std/fs/watch and the io engine are C backend only
// @skip-raiser
// note: a top-level await on a future the io engine owns (a file-watch batch) resumes with no program-side pump of msIoRunOnce: the main loop polls the engine while it holds an operation (old runtime: the await waited on the dispatcher port only and never returned). Workdir derives from argv[0] like the other engine corpus programs; a timer rewrites the file until the platform watcher delivers, because it delivers late and coalesced.

import { argv } from "std/process";
import { writeFile, removeAll, ensureDir, basename, dirname } from "std/fs";
import { watch, nextChanges, FsWatch } from "std/fs/watch";


const root = "/tmp/mscorpusTopAwaitEngine-" + basename(dirname(argv[0])) + "-" + basename(argv[0]);
removeAll(root);
ensureDir(root);

let rewrites = 0;
function churn(dir: string): number {
	return setInterval(() => {
		rewrites += 1;
		writeFile(`${dir}/churn.ms`, `export const n = ${rewrites};`);
	}, 20);
}

function open(dir: string): FsWatch {
	ensureDir(dir);
	const opened = watch(dir);
	if (!opened.ok) throw new Error("cannot watch " + dir);
	return opened.value;
}

const topDir = `${root}/top`;
const topWatch = open(topDir);
const topTimer = churn(topDir);
const top = await nextChanges(topWatch);
clearInterval(topTimer);
console.log(`top-level nextChanges names churn.ms: ${top.paths.join(",").includes("churn.ms")}`);

async function viaFunction(dir: string): Promise<boolean> {
	const w = open(dir);
	const timer = churn(dir);
	const batch = await nextChanges(w);
	clearInterval(timer);
	return batch.paths.join(",").includes("churn.ms");
}
console.log(`inside an async function: ${await viaFunction(`${root}/fn`)}`);
