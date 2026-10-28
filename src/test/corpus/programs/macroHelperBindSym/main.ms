// @stdout: found found 2
import { viaHelper, probeHelper, probeTwoDeep } from "./lib";

console.log(probeHelper(1) + " " + probeTwoDeep(1) + " " + String(viaHelper(1)));
