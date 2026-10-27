import { exit } from "std/process";
import { reload } from "std/hcr";
import { parse } from "../lib/lib";
import { clamp } from "../lib/deep/deep";

reload();
console.log(`HCR-STD ${parse("12")} ${parse("x")} ${clamp(-3)} ${clamp(4)}`);
exit(0);
