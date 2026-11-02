// Parity program — std/fs mkdirExclusive reports an existing path as AlreadyExists, and five
// threads claiming the same 200 names by it win each name exactly once. A rename is no such
// claim on Windows: two callers that opened the source before either moved it both succeed.
//
// @stdout: mkdirExclusive new=ok again=AlreadyExists overFile=AlreadyExists missingParent=NotFound mkdirAgain=ok
// @stdout: claims names=200 won=200
// @exit: 0
import { argv } from "std/process";
import { mkdir, mkdirExclusive, writeFile, removeAll, basename, dirname } from "std/fs";
import { IoError, IoErrorKind } from "std/io/errors";

function show(r: Result<void, IoError>): string {
	if (r.ok) return "ok";
	return match (r.error.kind) {
		IoErrorKind.NotFound => "NotFound",
		IoErrorKind.AlreadyExists => "AlreadyExists",
		_ => "Other",
	};
}

function claimAll(dir: string): number {
	let won = 0;
	for (let i = 0; i < 200; i++) {
		if (mkdirExclusive(`${dir}/claims/p${i}`).ok) won += 1;
	}
	return won;
}

const dir = "/tmp/mscorpusMkdirExclusive-" + basename(dirname(argv[0])) + "-" + basename(argv[0]);
removeAll(dir);
const made = mkdirExclusive(dir);
const again = mkdirExclusive(dir);
writeFile(`${dir}/f.txt`, "x");
console.log(`mkdirExclusive new=${show(made)} again=${show(again)} overFile=${show(mkdirExclusive(`${dir}/f.txt`))} missingParent=${show(mkdirExclusive(`${dir}/no/sub`))} mkdirAgain=${show(mkdir(dir))}`);

mkdir(`${dir}/claims`);
const workers: Promise<number>[] = [];
for (let w = 0; w < 4; w++) workers.push(spawn(() => claimAll(dir)));
let won = claimAll(dir);
for (const w of workers) won += await w;
console.log(`claims names=200 won=${won}`);

removeAll(dir);
