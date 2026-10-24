// Parity program — remove and removeAll delete a file whose write bit is cleared, as an
// unlink does on POSIX: alone, and nested two levels deep inside a tree removeAll walks.
// Workdir derives from argv[0] so concurrent lane cells never collide.
//
// @stdout: remove=ok gone=true removeAll=ok treeGone=true
// @exit: 0

import { argv } from "std/process";
import { writeFile, chmod, remove, removeAll, ensureDir, exists, basename, dirname } from "std/fs";

const dir = "/tmp/mscorpusReadOnly-" + basename(dirname(argv[0])) + "-" + basename(argv[0]);
removeAll(dir);
ensureDir(dir + "/a/b");

const single = dir + "/single.txt";
writeFile(single, "x");
chmod(single, 292 as int32);
const r = remove(single);

const nested = dir + "/a/b/nested.txt";
writeFile(nested, "y");
chmod(nested, 292 as int32);
const all = removeAll(dir);

console.log(`remove=${r.ok ? "ok" : "err"} gone=${!exists(single)} removeAll=${all.ok ? "ok" : "err"} treeGone=${!exists(dir)}`);
