import {
	Account,
	AssociatedToken,
	Mutable,
	Program,
	Pubkey,
	System,
	Token,
	Token2022,
	Writable,
	WritableSigner,
	address,
	bump,
	leBytes,
	seeds,
} from "std/solana";
import { CLOCK_ID } from "std/solana/pubkey";
import { anchorIdl } from "std/solana/idl";

enum VaultOp { Make, Take, Odd }

struct Escrow {
	seed: uint64;
	maker: Pubkey;
	bump: uint8;
}

struct MakeArgs {
	seed: uint64;
	flag: uint8;
	label: uint64;
}

struct MakeAccounts {
	maker: WritableSigner;
	@seeds("escrow", maker, leBytes(given.seed)) @bump escrow: Writable;
	@seeds("vault", [given.flag], [1, 2]) @bump vault: Writable;
	systemProgram: Program<System>;
	tokenProgram: Program<Token>;
	token2022Program: Program<Token2022>;
	associatedTokenProgram: Program<AssociatedToken>;
	@address(CLOCK_ID) clock: Account;
}

struct TakeAccounts {
	maker: Writable;
	@seeds("escrow", maker.key(), leBytes(escrow.seed)) @bump(escrow.bump) escrow: Mutable<Escrow>;
}

struct OddAccounts {
	maker: Writable;
	@seeds("a", maker, computed(given.label)) @bump computed: Writable;
	@seeds("b", leBytes(maker)) @bump wrongWidth: Writable;
	@seeds("c", leBytes(given.flag)) @bump narrow: Writable;
	@seeds("d", given.missing) @bump unknownArg: Writable;
	@address(maker.key()) runtime: Account;
}

function computed(value: uint64): uint8[8] { return leBytes(value); }

export function pdaSeedsIdl(): string {
	return anchorIdl<VaultOp>({
		name: "vault",
		Make: [MakeAccounts, MakeArgs],
		Take: [TakeAccounts],
		Odd: [OddAccounts, MakeArgs],
		accounts: [Escrow],
		events: [],
		errors: "",
	});
}

when (!testBuild) {
	console.log(pdaSeedsIdl());
}

test "a literal, an account and an argument seed give the account its PDA" {
	const idl = pdaSeedsIdl();
	assert idl.indexOf("{\"name\":\"escrow\",\"writable\":true,\"pda\":{\"seeds\":[" +
		"{\"kind\":\"const\",\"value\":[101,115,99,114,111,119]}," +
		"{\"kind\":\"account\",\"path\":\"maker\"}," +
		"{\"kind\":\"arg\",\"path\":\"seed\"}]}}") >= 0;
}

test "a one-byte argument and literal bytes are seeds, and @bump adds no seed" {
	const idl = pdaSeedsIdl();
	assert idl.indexOf("{\"name\":\"vault\",\"writable\":true,\"pda\":{\"seeds\":[" +
		"{\"kind\":\"const\",\"value\":[118,97,117,108,116]}," +
		"{\"kind\":\"arg\",\"path\":\"flag\"}," +
		"{\"kind\":\"const\",\"value\":[1,2]}]}}") >= 0;
}

test "a field of the account's own data is an account seed that names the account type" {
	const idl = pdaSeedsIdl();
	assert idl.indexOf("{\"name\":\"escrow\",\"writable\":true,\"pda\":{\"seeds\":[" +
		"{\"kind\":\"const\",\"value\":[101,115,99,114,111,119]}," +
		"{\"kind\":\"account\",\"path\":\"maker\"}," +
		"{\"kind\":\"account\",\"path\":\"escrow.seed\",\"account\":\"Escrow\"}]}}") >= 0;
}

test "every program the struct names by type has its fixed address" {
	const idl = pdaSeedsIdl();
	assert idl.indexOf("{\"name\":\"system_program\",\"address\":\"11111111111111111111111111111111\"}") >= 0;
	assert idl.indexOf("{\"name\":\"token_program\",\"address\":\"TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA\"}") >= 0;
	assert idl.indexOf("{\"name\":\"token2022_program\",\"address\":\"TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb\"}") >= 0;
	assert idl.indexOf("{\"name\":\"associated_token_program\",\"address\":\"ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL\"}") >= 0;
}

test "an @address that names an SDK constant gives the account that address" {
	const idl = pdaSeedsIdl();
	assert idl.indexOf("{\"name\":\"clock\",\"address\":\"SysvarC1ock11111111111111111111111111111111\"}") >= 0;
}

test "a seed the IDL cannot express leaves the account without a pda, as Anchor does" {
	const idl = pdaSeedsIdl();
	assert idl.indexOf("{\"name\":\"computed\",\"writable\":true}") >= 0;
	assert idl.indexOf("{\"name\":\"wrong_width\",\"writable\":true}") >= 0;
	assert idl.indexOf("{\"name\":\"narrow\",\"writable\":true}") >= 0;
	assert idl.indexOf("{\"name\":\"unknown_arg\",\"writable\":true}") >= 0;
	assert idl.indexOf("{\"name\":\"runtime\"}") >= 0;
}
