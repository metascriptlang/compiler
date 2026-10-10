import { account, accountCount } from "./core";
import { ProgramError } from "./error";
import { Pubkey } from "./pubkey";

when (testBuild) {
	import { failWith } from "./core";
	import { HostAccount, run } from "./host";
}

const MAX_MEMBERS: int32 = 32;

// The members among `members[0 .. length)` whose account signed, from account `first` on: a member
// listed twice counts once, so one key cannot meet a threshold alone.
export function signingMembers(
	first: int32,
	members: Readonly<Span<Pubkey>>,
	length: int32,
): Result<uint32, ProgramError> {
	if (length < 0 || length > members.length || length > MAX_MEMBERS) {
		return Result.err(ProgramError.invalidArgument());
	}
	let seen: uint32 = 0;
	let count: uint32 = 0;
	for (let index = first; index < accountCount(); index++) {
		const remaining = try account(index);
		if (!remaining.isSigner()) { continue; }
		for (let member = 0; member < length; member++) {
			if (remaining.key() == members[member]) {
				const bit = (1 as uint32) << (member as uint32);
				if ((seen & bit) == 0) {
					seen = seen | bit;
					count = count + 1;
				}
				break;
			}
		}
	}
	return Result.ok(count);
}

when (testBuild) {
	function keyOf(seed: uint8): Pubkey {
		let key = Pubkey.zero();
		key.bytes[0] = seed;
		return key;
	}

	function signer(seed: uint8, signs: boolean): HostAccount {
		return {
			key: keyOf(seed),
			owner: Pubkey.zero(),
			lamports: 0,
			data: [],
			signer: signs,
			writable: false,
			executable: false,
		};
	}

	function countEntry(): void {
		const members: Pubkey[3] = [keyOf(1), keyOf(2), keyOf(3)];
		const counted = signingMembers(0, members, 3);
		if (!counted.ok) { failWith(counted.error); return; }
		failWith(ProgramError.userError(counted.value));
	}

	// The entry reports the count as userError(count), the one value a host run hands back.
	function counted(accounts: HostAccount[]): int32 {
		const empty: uint8[] = [];
		const result = run(keyOf(9), accounts, empty, countEntry).result;
		for (let n: uint32 = 0; n <= 4; n++) {
			if (result == ProgramError.userError(n).code) { return n as int32; }
		}
		return -1;
	}

	test "a member listed twice counts once, so one key cannot meet a threshold of two" {
		assert counted([signer(1, true), signer(1, true)]) == 1;
		assert counted([signer(1, true), signer(2, true)]) == 2;
		assert counted([signer(1, true), signer(1, true), signer(3, true), signer(3, true)]) == 2;
	}

	test "an account that did not sign or is not a member is not counted" {
		assert counted([signer(1, false), signer(2, true)]) == 1;
		assert counted([signer(7, true), signer(8, true)]) == 0;
		assert counted([]) == 0;
	}
}
