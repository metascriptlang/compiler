import { reload } from "std/hcr";
import { Counter, Keeper } from "./logic";

const keeper = new Keeper("kept");
const counter = new Counter();
reload();
console.log(`NEW ${keeper.text} ${counter.count}`);
