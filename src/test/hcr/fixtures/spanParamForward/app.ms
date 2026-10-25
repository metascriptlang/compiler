import { reload } from "std/hcr";
import { total, joined, pair } from "./lib";

const xs: int32[] = [1, 2, 3, 4];
reload();
const [a, b] = pair();
const kept = joined("+", ["x", "y"]);
console.log(`HCR-SPAN ${total(xs)} ${joined("-", ["a", "b", "c"])} ${kept} ${a}${b}`);
