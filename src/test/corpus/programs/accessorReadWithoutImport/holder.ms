import { Counter, Box } from "./counter";
export class Holder {
	counter: Counter = new Counter();
	box: Box<string> = new Box<string>("boxed");
}
