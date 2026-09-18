// @stdout: emission-ownership PASS OLRM
import { left, leftScore } from "./left";
import { right, rightScore } from "./right";
import { events, record } from "./state";
import { unused } from "./dead";
import { heldLabel } from "./owner";
import { exit } from "std/process";
record("M");
function main(): void {
	const a = left();
	const b = right();
	if (heldLabel() != "held" || leftScore() + rightScore() != 14 || a.children[0].label != "leaf" || b.label != "right" || events != "OLRM") {
		console.log("emission-ownership FAIL " + events);
		exit(1);
	}
	console.log("emission-ownership PASS " + events);
}
main();
