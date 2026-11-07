// A string's JSON text appended to the output.

import { appendEscapedPortable } from "./escape";

export function appendEscaped(ref out: string, s: string): void {
	appendEscapedPortable(out, s);
}
