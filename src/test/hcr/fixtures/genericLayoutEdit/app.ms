import { reload } from "std/hcr";
import { describe } from "./holder";

reload();
console.log(`LAYOUT ${describe()}`);
