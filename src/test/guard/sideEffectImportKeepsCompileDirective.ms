import { exit } from "std/process";
import {
	sideEffectImportDirect,
	sideEffectImportChained,
} from "./fixtures/sideEffectImport/bridge.h";
import "./fixtures/sideEffectImport/direct";
import "./fixtures/sideEffectImport/chain";

function main(): void {
	const direct = sideEffectImportDirect();
	const chained = sideEffectImportChained();
	console.log(`direct=${direct} chained=${chained}`);
	if (direct != 42 || chained != 7) {
		console.log("FAIL: a directive of a side-effect import was dropped");
		exit(1);
	}
	console.log("sideEffectImportKeepsCompileDirective ok");
}

main();
