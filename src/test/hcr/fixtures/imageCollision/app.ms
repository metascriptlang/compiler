import { reload } from "std/hcr";
import { one } from "./a/b";
import { two } from "./a.b";
reload();
console.log(`${one() + two()}`);
