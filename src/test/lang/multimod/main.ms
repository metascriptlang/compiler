// Cross-module test — imports from sibling module
// Run: msc run examples/testMultiMod/main.ms

import { Level, Message, makeMsg, formatMsg, levelName, maxNum, minNum, clamp, repeatStr, padLeft } from "./utils";

// ===== Compose imported functions =====
function logMessages(msgs: Message[]): string {
	let result = "";
	let i = 0;
	while (i < msgs.length) {
		if (i > 0) result = result + "\n";
		result = result + formatMsg(msgs[i]);
		i += 1;
	}
	return result;
}

test "Cross-module enum" {
	assert levelName(Level.Debug) == "DEBUG";
	assert levelName(Level.Error) == "ERROR";
}

test "Cross-module interface" {
	const msg = makeMsg(Level.Info, "server started");
	assert msg.level == Level.Info;
	assert msg.text == "server started";
}

test "Cross-module function" {
	const formatted = formatMsg(makeMsg(Level.Info, "server started"));
	assert formatted == "[INFO] server started";

	const warnMsg = makeMsg(Level.Warn, "low memory");
	assert formatMsg(warnMsg) == "[WARN] low memory";
}

test "Utility functions" {
	assert maxNum(3, 7) == 7;
	assert maxNum(10, 2) == 10;
	assert minNum(3, 7) == 3;
	assert clamp(5, 0, 10) == 5;
	assert clamp(-3, 0, 10) == 0;
	assert clamp(15, 0, 10) == 10;
}

test "String utilities" {
	assert repeatStr("ab", 3) == "ababab";
	assert repeatStr("x", 0) == "";
	assert padLeft("42", 5, "0") == "00042";
	assert padLeft("hello", 3, "0") == "hello";
}

test "Composition" {
	const msgs: Message[] = [];
	msgs.push(makeMsg(Level.Info, "boot"));
	msgs.push(makeMsg(Level.Debug, "init"));
	msgs.push(makeMsg(Level.Error, "crash"));
	const logOutput = logMessages(msgs);
	assert logOutput == "[INFO] boot\n[DEBUG] init\n[ERROR] crash";
}

console.log("Done.");
