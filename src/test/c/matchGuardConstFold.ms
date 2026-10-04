import { compileToC } from "../helpers";

const CAP615: int32 = 12000;
const NESTED615: int32 = CAP615 / 2;

function capped615(value: int32): int32 {
	return match (value) {
		_ when value > CAP615 => CAP615,
		_ when value > NESTED615 => NESTED615,
		_ => value,
	};
}

function picked615(): int32 {
	let picked: int32 = 0;
	match (capped615(7000)) {
		_ when CAP615 > NESTED615 => { picked = NESTED615; },
		_ => { picked = 0; },
	}
	return picked;
}

test "matchGuardConstFold: guard consts cap at each level" {
	assert capped615(20000) == 12000;
	assert capped615(7000) == 6000;
	assert capped615(5) == 5;
	assert picked615() == 6000;
}

test "matchGuardConstFold: every guard use of a module const folds, leaving only the definition" {
	const src = `
const FCAP615: int32 = 12000;
const FNESTED615: int32 = FCAP615 / 2;
function fcapped615(value: int32): int32 {
	return match (value) {
		_ when value > FCAP615 => FCAP615,
		_ when value > FNESTED615 => FNESTED615,
		_ => value,
	};
}
function fpicked615(): int32 {
	let picked: int32 = 0;
	match (fcapped615(7000)) {
		_ when FCAP615 > FNESTED615 => { picked = FNESTED615; },
		_ => { picked = 0; },
	}
	return picked;
}
`;
	const result = compileToC(src);
	assert result.ok, result.error;
	const c = result.value;
	const capFirst = c.indexOf("FCAP615");
	const capLast = c.lastIndexOf("FCAP615");
	assert capFirst >= 0 && capFirst == capLast,
		"FCAP615 read outside its definition — a guard still reads the global";
	const nestedFirst = c.indexOf("FNESTED615");
	assert nestedFirst >= 0 && nestedFirst == c.lastIndexOf("FNESTED615"),
		"FNESTED615 read outside its definition";
	assert c.indexOf("value > 12000") >= 0, "guard comparison did not inline 12000";
	assert c.indexOf("> 6000") >= 0, "second guard did not inline the folded 6000";
}
