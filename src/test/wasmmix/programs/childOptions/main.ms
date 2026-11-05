// @columns: mixed
// @stdout: 15
// @stdout: a=b with space λ
// @stdout: true
// @stdout: true
import { define } from "std/meta";
import { targetFlags, label, projectDirectory, emptyValue } from "./childOptionsWasm";

const project = @comptime { return define("projectDir"); };
console.log(targetFlags());
console.log(label());
console.log(projectDirectory() == project);
console.log(emptyValue() == "");
