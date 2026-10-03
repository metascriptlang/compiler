// Parked at inbox card 2026-09-25-fixedbugs-tier-old-reds.md
import { evalSourceFull } from "../../codegen/raiser/eval";

test "comptime values: unsupported evaluation" {
	const cases = [
		{ name: "signed narrowing out of range is an error, as at runtime r", source: "const i: int32 = 300; return i as int8;", low: 0, high: 0 },
	];
	for (const item of cases) {
		const result = evalSourceFull(item.source);
		assert result.lastError != "", item.name;
	}
}
