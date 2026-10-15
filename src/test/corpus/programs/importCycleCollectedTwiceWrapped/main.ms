// @stdout: 1
// note: entering the cycle through draw makes the first phase reach scene from inside skinGeo, collect it there, and collect it again when the walk unwinds; skinGeo kept the first collect's types, which no later phase upgraded, so the C build stopped with "unresolved type (kind=48) reached codegen".
import { MeshId } from "./draw";
import { create } from "./scene";

const m: MeshId = { index: 1 };
console.log(`${m.index + create().meshes.length}`);
