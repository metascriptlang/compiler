// Parity program — std/os homeDir() resolves on C and Raiser and reads the variable the C runtime
// reads: USERPROFILE on Windows, HOME elsewhere.
// Axes: the inherited value, a value the program sets, the variable unset; EOL.
//
// @skip-js: std/os has no JS surface
// @stdout: inherited ok|set /corpus822/home|unset <>|eol 1
// @exit: 0

import { homeDir, EOL } from "std/os";
import { env, platform } from "std/process";

const name = platform == "windows" ? "USERPROFILE" : "HOME";
const inherited = env.get(name);
const seen = homeDir() == inherited && inherited.length > 0 ? "ok" : "bad";
env.set(name, "/corpus822/home");
const set = homeDir();
env.delete(name);
const unset = homeDir();
console.log(`inherited ${seen}|set ${set}|unset <${unset}>|eol ${EOL.length}`);
