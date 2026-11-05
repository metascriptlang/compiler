// @stdout: comptime [686920c3a9] [aGkgw6k=] [hi é] [hi é] | [] [] [] []
// @stdout: runtime [686920c3a9] [aGkgw6k=] [hi é] [hi é] | [] [] [] []
// note: a helper the build checked runs std's hex and base64 codec at comptime through the codec's `when (raiser)` block (an empty input included, whose native path returns a C extern), and prints what the build's own code prints at run time.
import { codecLine } from "./lib";

const atCompile = @comptime { return `${codecLine("hi é")} | ${codecLine("")}`; };
console.log(`comptime ${atCompile}`);
console.log(`runtime ${codecLine("hi é")} | ${codecLine("")}`);
