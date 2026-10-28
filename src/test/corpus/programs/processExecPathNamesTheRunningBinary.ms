// @stdout: absolute true named true
// @stdout: execPath absolute true exists true
// note: std/process execPath is the running executable as the OS reports it, an absolute path to a file that exists, on every backend.
import { execPath } from "std/process";
import { exists } from "std/fs";
import { isAbsolute } from "std/fs/path";

const absolute = execPath.startsWith("/") || (execPath.length > 2 && execPath[1] == ":");
const base = execPath.replaceAll("\\", "/").split("/").pop() ?? "";
console.log(`absolute ${absolute} named ${base.length > 0}`);
console.log(`execPath absolute ${isAbsolute(execPath)} exists ${exists(execPath)}`);
