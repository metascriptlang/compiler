// A member of an enum declared in a C header is defined, exported and read under one name on
// every backend: read directly from the header, through a re-exporting hub, as a parameter, a
// switch case and a comparison, with ordinal and explicit negative values.
// @stdout: 1 0|-1 9|high|true false|4
// @exit: 0

import { PinTone } from "./tone.h";
import { PinLevel } from "./hub";

function pick(high: boolean): PinTone {
	return high ? PinTone.PinToneHigh : PinTone.PinToneLow;
}

function name(t: PinTone): string {
	switch (t) {
		case PinTone.PinToneHigh: return "high";
		default: return "low";
	}
}

const level: PinLevel = PinLevel.PinLevelDim;
console.log(`${pick(true) as int32} ${pick(false) as int32}|${PinLevel.PinLevelOff as int32} ${PinLevel.PinLevelFull as int32}|${name(pick(true))}|${level == PinLevel.PinLevelDim} ${level == PinLevel.PinLevelFull}|${level as int32}`);
