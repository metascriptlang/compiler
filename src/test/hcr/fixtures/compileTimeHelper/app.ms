import { reload } from "std/hcr";
import { kindOf, label } from "./shapes";

struct Point {
	x: int32;
}

reload();
console.log(`HCR-CT ${label()} ${kindOf(Point)}`);
