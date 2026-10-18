// @stdout: n3 sx f2 ns sy n5 sz
// note: an extension declared as a later overload of a plain function stays a method for an importer, whether the import is named, through a namespace or through a re-exporting module.
import { tag } from "./lib";
import { viaNamespace } from "./viaNamespace";
import { viaHub } from "./viaHub";

const f: float64 = 1.5;
console.log(tag(3), "x".tag(), f.tag(2), viaNamespace(), viaHub());
