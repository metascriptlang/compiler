import { readFile, exists } from "std/fs";

const file = readFile("emccStdFsMissing.txt");
console.log(file.ok ? "read" : "not read");
console.log(exists("emccStdFsMissing.txt") ? "exists" : "absent");
