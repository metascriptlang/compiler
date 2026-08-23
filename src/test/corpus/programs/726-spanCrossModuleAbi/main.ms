import { parse } from "./decode";

const buf: uint8[] = [7, 8, 9];
console.log("xmod=" + parse(buf));
console.log("lit=" + parse([1, 2, 3]));
const empty: uint8[] = [];
console.log("empty-len=" + empty.length.toString());
