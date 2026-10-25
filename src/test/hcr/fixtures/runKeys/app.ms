import { readFile, writeFile } from "std/fs";
import { reload, ReloadKind } from "std/hcr";
import { value } from "./logic";

console.log(`HCR-KEYS start ${value()}`);
const current = readFile("logic.ms");
const grown = readFile("grown.txt");
if (!current.ok || !grown.ok) {
	console.log("HCR-KEYS cannot read the sources");
} else if (!current.value.contains("9") && !writeFile("logic.ms", grown.value).ok) {
	console.log("HCR-KEYS cannot write logic.ms");
}
let said = false;
while (true) {
	if (reload() == ReloadKind.Reloaded && !said) {
		console.log(`HCR-KEYS reloaded ${value()}`);
		said = true;
	}
	await sleepAsync(20);
}
