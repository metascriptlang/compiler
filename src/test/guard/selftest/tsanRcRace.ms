// SELFTEST-RED ThreadSanitizer
// GUARD-TSAN

@passC("-I../../../../runtime");
@compile("../fixtures/rcRaceProbe.c");

import { rcRaceProbe } from "../fixtures/rcRaceProbe.h";

console.log(rcRaceProbe());
console.log("GUARD-OK");
