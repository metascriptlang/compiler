import { ProgramError } from "./error";
import { HostAccount, NOT_SIMULATED, run } from "./host";
import { Pubkey, SYSTEM_PROGRAM_ID } from "./pubkey";
import { FORWARD, NONE, hostProgramEntry } from "./testHostProgram";

function keyOf(seed: uint8): Pubkey {
	let key = Pubkey.zero();
	key.bytes[0] = seed;
	return key;
}

function systemCall(instruction: uint8[]): [uint64, string] {
	const data: uint8[] = [FORWARD, NONE, 1, 3, 0, 0, 0, 0, 0, 0];
	for (const byte of instruction) { data.push(byte); }
	const program: HostAccount = {
		key: SYSTEM_PROGRAM_ID, owner: keyOf(0), lamports: 1, data: [], signer: false, writable: false, executable: true,
	};
	const wallet: HostAccount = {
		key: keyOf(1), owner: SYSTEM_PROGRAM_ID, lamports: 1000000000, data: [], signer: true, writable: true, executable: false,
	};
	const outcome = run(keyOf(9), [program, wallet], data, hostProgramEntry);
	return [outcome.result, outcome.fault];
}

test "System instruction data under four bytes is InvalidInstructionData, not a tag" {
	const invalid = ProgramError.invalidInstructionData().code;
	for (const length of [0, 1, 3]) {
		const sent: uint8[] = [];
		for (let index = 0; index < length; index++) { sent.push(2); }
		const [result, fault] = systemCall(sent);
		assert result == invalid && fault == "";
	}
}

test "a System tag the simulator does not carry fails the run as not simulated and names the tag" {
	for (const tag of [3, 5, 7, 12, 14, 255]) {
		const [result, fault] = systemCall([tag as uint8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
		assert result == NOT_SIMULATED;
		assert fault == `sol_invoke_signed: System program instruction ${tag} is not simulated`;
	}
	const [wide, wideFault] = systemCall([255, 255, 255, 255]);
	assert wide == NOT_SIMULATED && wideFault.indexOf("instruction 4294967295 is not simulated") > 0;
}
