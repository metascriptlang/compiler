// @stdout: 4 8 true false 20
// note: holder.ms reaches the 20-member enum through an import cycle, so its set
// is resolved before the enum's module finishes; the set must still be four bytes wide.
import { run } from "./holder";

run();
