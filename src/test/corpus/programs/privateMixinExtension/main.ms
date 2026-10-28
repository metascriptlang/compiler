// Parity program — a generic in another module calls convention extensions on its type parameter,
// and the calling module's extensions reach it although they are not exported: the instance
// resolves them where it is instantiated and links to them on every backend.
//
// @stdout: total=4 depths=0,1,2,1
// @exit: 0

import { walkTree } from "./lib/index";

interface Panel { name: string; children: Panel[]; depth: int32; }

function protoKids(this p: Panel): Panel[] { return p.children; }
function protoBump(this p: Panel, v: int32): void { p.depth = v; }

const leaf: Panel = { name: "leaf", children: [], depth: -1 };
const mid: Panel = { name: "mid", children: [leaf], depth: -1 };
const side: Panel = { name: "side", children: [], depth: -1 };
const root: Panel = { name: "root", children: [mid, side], depth: -1 };
const total = walkTree(root, 0);
console.log(`total=${total} depths=${root.depth},${mid.depth},${leaf.depth},${side.depth}`);
