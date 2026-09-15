import { emitIface } from "./fixtures/macroDeclOrder/emitIface";
import { emitValue } from "./fixtures/macroDeclOrder/emitValue";
import { emitViaBound } from "./fixtures/macroDeclOrder/emitViaBound";
import { emitJsxSeen } from "./fixtures/macroDeclOrder/emitJsxSeen";
import { exit } from "std/process";

function readBeforeTheCall(): float64 {
	const local: MacroEmitted = { a: 5 };
	return local.a;
}

function valueBeforeTheCall(): int32 {
	return macroEmittedValue + 1;
}

function takesEmittedParam(p: MacroEmitted): float64 {
	return p.a;
}

function boundBeforeTheCall(): float64 {
	const local: BoundEmitted = { b: 11 };
	return local.b;
}

function jsxSeenBeforeTheCall(): int32 {
	return jsxSeen;
}

class HolderAboveTheCall {
	read(): float64 {
		const local: MacroEmitted = { a: 3 };
		return local.a;
	}
}

emitIface(0);
emitValue(0);
emitViaBound(0);
emitJsxSeen(aliasBelowTheCall);

const aliasBelowTheCall = <div />;

const annotatedAtTopLevel: MacroEmitted = { a: 7 };

const fromBody = readBeforeTheCall();
const fromParam = takesEmittedParam({ a: 9 });
const fromMethod = new HolderAboveTheCall().read();
const fromValue = valueBeforeTheCall();
const fromBound = boundBeforeTheCall();
const fromJsx = jsxSeenBeforeTheCall();

console.log(`body=${fromBody} top=${annotatedAtTopLevel.a} param=${fromParam} method=${fromMethod} value=${fromValue} bound=${fromBound} jsx=${fromJsx}`);

if (fromBody != 5) {
	console.log("GUARD-FAIL a body above the macro call lost the emitted type");
	exit(1);
}

if (annotatedAtTopLevel.a != 7) {
	console.log("GUARD-FAIL a top-level annotation lost the emitted type");
	exit(1);
}

if (fromParam != 9) {
	console.log("GUARD-FAIL a parameter annotation above the macro call lost the emitted type");
	exit(1);
}

if (fromMethod != 3) {
	console.log("GUARD-FAIL a method body above the macro call lost the emitted type");
	exit(1);
}

if (fromValue != 42) {
	console.log("GUARD-FAIL a body above the macro call lost the emitted value");
	exit(1);
}

if (fromBound != 11) {
	console.log("GUARD-FAIL a body above the call lost a type emitted through a bound macro");
	exit(1);
}

if (fromJsx != 1) {
	console.log("GUARD-FAIL a JSX alias declared below the call reached the macro unfolded");
	exit(1);
}

console.log("GUARD-OK");
