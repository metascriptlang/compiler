// @stdout: B2 A1 As | A1 B2 | B3B3
import { wrap as wa } from "./a";
import { wrap as wb, wrapTwice } from "./b";

const bFirst = `${wb(2 as int32)} ${wa(1 as int32)} ${wa("s")}`;
const aFirst = `${wa(1 as int32)} ${wb(2 as int32)}`;
console.log(`${bFirst} | ${aFirst} | ${wrapTwice(3 as int32)}`);
