import { reload } from "std/hcr";

function check(): void {
	throw new Error("boom: the reason the author needs");
}
check();
while (true) { reload(); }
