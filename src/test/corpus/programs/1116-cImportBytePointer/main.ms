// @stdout: 251 251 5
// @skip-js: a C header import binds C symbols; the JS backend has no C linkage
// note: a header's `unsigned char *` and `uint8_t *` point at bytes, so they import as a
// borrowed uint8, not as cstring; plain `char *` stays cstring. Both byte forms used to be
// cstring and refused a uint8 argument.
import { bytesSum, bytesSum8, textLen } from "./bytes.h";
let bytes: Vec<uint8> = new Array(3);
bytes[0] = 1;
bytes[1] = 0;
bytes[2] = 250;
console.log(`${bytesSum(bytes[0], 3)} ${bytesSum8(bytes[0], 3)} ${textLen("hello")}`);
