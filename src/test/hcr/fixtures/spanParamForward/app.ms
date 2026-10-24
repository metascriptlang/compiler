import { reload } from "std/hcr";
import { total, joined } from "./lib";

const xs: int32[] = [1, 2, 3, 4];
reload();
console.log(`HCR-SPAN ${total(xs)} ${joined("-", ["a", "b", "c"])}`);
