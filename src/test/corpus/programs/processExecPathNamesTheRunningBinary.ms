// @stdout: absolute true named true
import { execPath } from "std/process";

const absolute = execPath.startsWith("/") || (execPath.length > 2 && execPath[1] == ":");
const base = execPath.replaceAll("\\", "/").split("/").pop() ?? "";
console.log(`absolute ${absolute} named ${base.length > 0}`);
