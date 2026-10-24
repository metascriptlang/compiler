// @selftest-red ThreadSanitizer
@passC("-I../../../../runtime");
@compile("../../guard/fixtures/rcRaceProbe.c");

import { rcRaceProbe } from "../../guard/fixtures/rcRaceProbe.h";

console.log(rcRaceProbe());
