// @skip-js: the js target checks std/process from its host-API variant, which the compile-time VM cannot run
// @stdout: true [] true
import { env, findOnPath } from "std/process";
import { pathLength, unsetVar, foundOnPath } from "./lib";

console.log(String(pathLength(0) == env.get("PATH").length.toString()) + " " + unsetVar(0) + " " + String(foundOnPath(0) == findOnPath("msc")));
