import { wrap, count, Box, ownBox, summary } from "./lib";

const held: unknown = new Box<int32>(7);
const shared = ownBox() as Box<string>;
console.log(`JS-INST first ${wrap(1).length} ${(held as Box<int32>).get()} ${shared.get()} ${count(2)} ${summary()}`);
