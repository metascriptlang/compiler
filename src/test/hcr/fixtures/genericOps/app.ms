import { reload } from "std/hcr";
import { left } from "./left";
import { right } from "./right";

reload();
console.log("OPS " + left().toString() + " " + right());
