import { reload } from "std/hcr";
import { Base, Counter, Keeper } from "./logic";

class Child extends Base {
	constructor() {
		super("child");
	}
}

const keeper = new Keeper("kept");
const counter = new Counter();
const child = new Child();
reload();
console.log(`NEW ${keeper.text} ${counter.count} ${child.label}`);
