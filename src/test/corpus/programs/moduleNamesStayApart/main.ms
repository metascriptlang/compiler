// @stdout: underscore digits upper number | slash dir
// note: module paths that differ only in how a byte is spelled (`a_b` / `a95b`, `Q` / `81`, `ab` / `a/b`) keep distinct C symbols; the link used to fail with duplicate definitions.
import { f as underscore } from "./a_b";
import { f as digits } from "./a95b";
import { f as upper } from "./Q";
import { f as numeric } from "./81";
import { f as flat } from "./ab";
import { f as nested } from "./a/b";
console.log(`${underscore()} ${digits()} ${upper()} ${numeric()} | ${flat()} ${nested()}`);
