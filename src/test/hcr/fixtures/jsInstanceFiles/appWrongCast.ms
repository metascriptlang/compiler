import { wrap, count, Box, ownBox, summary } from "./lib";

const held: unknown = new Box<int32>(7);
const shared = ownBox() as Box<string>;
console.log(`JS-INST first ${wrap(1).length} ${(held as Box<int32>).get()} ${shared.get()} ${count(2)} ${summary()}`);
const flag: unknown = new Box<boolean>(true);
const text = new Box<string>("app");
console.log(`JS-INST second ${wrap(true).length} ${(flag as Box<boolean>).get()} ${text.get()} ${count(3)} ${summary()}`);
const wrong = flag as Box<int32>;
console.log(`JS-INST wrong ${wrong.get()}`);
