export const DATA = {
	Config: [["authority", "Pubkey"], ["vrfQueue", "Pubkey"], ["skrMint", "Pubkey"], ["treasury", "Pubkey"], ["hbrnMint", "Pubkey"], ["bump", "uint8"]],
	Policy: [["bump", "uint8"]],
	World: [["bump", "uint8"]],
	Block: [["id", "uint32"], ["bump", "uint8"]],
	PetAccount: [["owner", "Pubkey"], ["mint", "Pubkey"], ["bump", "uint8"]],
	Receipt: [["pet", "Pubkey"], ["nonce", "uint64"], ["bump", "uint8"]],
	Resort: [["bump", "uint8"]],
	VrfPayer: [["bump", "uint8"]],
};

const field = (name, type, ...decos) => ({ name, type, decos });
const seeds = (list, bump) => ({ d: "seeds", seeds: list, bump });
const text = (value) => ({ text: value });
const hasOne = (name, error) => ({ d: "hasOne", name, error });
const address = (key, error) => ({ d: "address", key, error });
const NOT_AUTHORITY = "hibernalError(HibernalError.NotAuthority)";
const INCORRECT_PROGRAM = "ProgramError.incorrectProgramId()";
const INVALID_ARGUMENT = "ProgramError.invalidArgument()";

const configSeeds = (name = "config") => seeds([text("config")], `${name}.bump`);
const ownerProgram = () => field("ownerProgram", "Account", address({ own: true }, INCORRECT_PROGRAM));
const delegationProgram = () => field("delegationProgram", "Account", address({ wk: "delegationProgram" }, INCORRECT_PROGRAM));
const vrfPayer = () => field("payer", "Mutable<VrfPayer>", seeds([text("vrf-payer")], "payer.bump"));
const petSeeds = () => seeds([text("pet"), { data: ["pet", "mint"] }], "pet.bump");
const accounts = (...names) => names.map((name) => field(name, "Account"));
const writables = (...names) => names.map((name) => field(name, "Writable"));
const delegation = () => [
	ownerProgram(),
	...writables("buffer", "delegationRecord", "delegationMetadata"),
	delegationProgram(),
	field("systemProgram", "Program<System>"),
];

export function hibernalShapes() {
	return [
		{ name: "InitializeAccounts", fields: [field("authority", "WritableSigner"), ...writables("config", "policy", "world", "mint"), field("tokenProgram", "Program<Token>"), field("systemProgram", "Program<System>")] },
		{ name: "WritePolicyAccounts", fields: [
			field("authority", "WritableSigner"),
			field("config", "Mutable<Config>", configSeeds(), hasOne("authority", NOT_AUTHORITY)),
			field("policy", "Mutable<Policy>", seeds([text("policy")], "policy.bump")),
		] },
		{ name: "CreateBlockAccounts", fields: [
			field("authority", "WritableSigner"),
			field("config", "Mutable<Config>", configSeeds(), hasOne("authority", NOT_AUTHORITY)),
			field("block", "Writable"),
			field("systemProgram", "Program<System>"),
		] },
		{ name: "DelegateVrfPayerAccounts", fields: [
			field("authority", "WritableSigner"),
			field("config", "Owned<Config>", hasOne("authority", NOT_AUTHORITY)),
			field("vrfPayer", "Writable"),
			...delegation(),
		] },
		{ name: "ClaimAccounts", fields: [
			field("owner", "WritableSigner"),
			field("config", "Mutable<Config>", configSeeds()),
			field("mint", "External<Mint>"),
			field("held", "External<TokenAccount>", { d: "tokenAuthority", key: { field: "owner" } }, { d: "tokenMint", key: { field: "mint" } }),
			...writables("pet", "paid"),
			field("systemProgram", "Program<System>"),
		] },
		{ name: "DelegatePetAccounts", fields: [
			field("payer", "WritableSigner", {
				d: "constraint",
				std: "payer.key() == delegated.owner || payer.key() == config.authority",
				table: "$accounts.payer.key() == $accounts.delegated.data().owner || $accounts.payer.key() == $accounts.config.data().authority",
				error: "hibernalError(HibernalError.NotTheOwner)",
				claims: { owner: "delegated", member: "owner", by: "payer" },
			}),
			field("config", "Owned<Config>", configSeeds()),
			field("delegated", "Mutable<PetAccount>"),
			...delegation(),
		] },
		{ name: "DelegateBlockAccounts", fields: [
			field("payer", "WritableSigner", address({ data: ["config", "authority"] }, NOT_AUTHORITY)),
			field("config", "Owned<Config>", configSeeds()),
			field("delegated", "Mutable<Block>"),
			...delegation(),
		] },
		{ name: "DelegateWorldAccounts", fields: [
			field("payer", "WritableSigner", address({ data: ["config", "authority"] }, NOT_AUTHORITY)),
			field("config", "Owned<Config>", configSeeds()),
			field("delegated", "Mutable<World>"),
			...delegation(),
		] },
		{ name: "UndelegationAccounts", fields: [field("delegated", "Writable"), field("buffer", "Account"), field("payer", "Writable"), field("systemProgram", "Program<System>")] },
		{ name: "PlaceAccounts", fields: [
			field("authority", "WritableSigner", address({ data: ["config", "authority"] }, NOT_AUTHORITY)),
			field("config", "Owned<Config>", configSeeds()),
			field("world", "Mutable<World>", seeds([text("world")], "world.bump")),
			field("block", "Mutable<Block>", seeds([text("block"), { le: { of: "block", member: "id", cast: "uint64", width: 8 } }], "block.bump")),
			field("pet", "Mutable<PetAccount>", petSeeds()),
		] },
		{ name: "RoundStartAccounts", fields: [
			vrfPayer(),
			field("config", "Owned<Config>"),
			field("world", "Owned<World>"),
			field("block", "Mutable<Block>"),
			field("programIdentity", "Account"),
			field("oracleQueue", "Account", address({ data: ["config", "vrfQueue"] }, INVALID_ARGUMENT)),
			...accounts("slotHashes", "systemProgram", "vrfProgram", "nextCrank", "magicVault", "magicProgram", "hydraProgram"),
		] },
		{ name: "TurnAccounts", fields: [
			vrfPayer(),
			field("config", "Owned<Config>"),
			field("world", "Mutable<World>"),
			field("block", "Mutable<Block>"),
			field("policy", "Owned<Policy>"),
			field("programIdentity", "Account"),
			field("oracleQueue", "Account", address({ data: ["config", "vrfQueue"] }, INVALID_ARGUMENT)),
			...accounts("slotHashes", "systemProgram", "vrfProgram", "nextCrank", "magicVault", "magicProgram", "hydraProgram"),
		] },
		{ name: "SeededAccounts", fields: [field("identity", "Account"), field("block", "Mutable<Block>")] },
		{ name: "StartBlockAccounts", fields: [
			field("authority", "Signer", address({ data: ["config", "authority"] }, NOT_AUTHORITY)),
			field("config", "Owned<Config>"),
			field("world", "Owned<World>"),
			field("block", "Mutable<Block>"),
			vrfPayer(),
			...accounts("crank", "magicVault", "magicProgram", "hydraProgram"),
		] },
		{ name: "SweepAccounts", fields: [vrfPayer(), ...accounts("magicVault", "magicProgram", "hydraProgram")] },
		{ name: "CrankAccounts", fields: [
			field("sponsor", "Account"),
			field("crank", "Account"),
			field("magicVault", "Account", address({ user: "magicVault" }, INVALID_ARGUMENT)),
			field("magicProgram", "Account", address({ user: "magicProgram" }, INCORRECT_PROGRAM)),
			field("hydraProgram", "Account", address({ user: "hydraProgram" }, INCORRECT_PROGRAM)),
		] },
		{ name: "OwnerAccounts", fields: [
			field("owner", "Signer"),
			field("pet", "Mutable<PetAccount>", petSeeds(), hasOne("owner")),
			field("world", "Owned<World>"),
		] },
		{ name: "CommitPetAccounts", fields: [
			field("owner", "Signer"),
			field("pet", "Mutable<PetAccount>", petSeeds(), hasOne("owner")),
			vrfPayer(),
			field("magicContext", "Writable", address({ user: "magicContext" })),
			field("magicFeeVault", "Writable"),
			field("magicProgram", "Account", address({ user: "magicProgram" })),
		] },
		{ name: "ClaimRewardAccounts", fields: [
			field("owner", "WritableSigner"),
			field("config", "Owned<Config>"),
			field("pet", "Account"),
			field("paid", "Writable"),
			field("mint", "ExternalMutable<Mint>", address({ data: ["config", "hbrnMint"] })),
			field("destination", "ExternalMutable<TokenAccount>", { d: "tokenAuthority", key: { field: "owner" } }, { d: "tokenMint", key: { data: ["config", "hbrnMint"] } }),
			field("tokenProgram", "Account", {
				d: "constraint",
				std: "tokenProgram.key() == mint.owner()",
				table: "$accounts.tokenProgram.key() == $accounts.mint.owner()",
			}),
			field("systemProgram", "Program<System>"),
		] },
		{ name: "BuyAccounts", fields: [
			field("owner", "WritableSigner"),
			field("config", "Owned<Config>", configSeeds()),
			field("pet", "Delegated<PetAccount>", petSeeds(), hasOne("owner")),
			field("skrMint", "External<Mint>", address({ data: ["config", "skrMint"] })),
			field("source", "ExternalMutable<TokenAccount>"),
			field("treasury", "ExternalMutable<TokenAccount>", address({ data: ["config", "treasury"] })),
			field("receipt", "Writable"),
			...delegation().slice(0, 5),
			field("tokenProgram", "Account"),
			field("systemProgram", "Program<System>"),
		] },
		{ name: "ConsumeAccounts", fields: [
			field("receipt", "Mutable<Receipt>", seeds([text("receipt"), { data: ["receipt", "pet"] }, { le: { of: "receipt", member: "nonce", width: 8 } }], "receipt.bump"), hasOne("pet")),
			field("pet", "Mutable<PetAccount>", petSeeds()),
			field("world", "Owned<World>", seeds([text("world")], "world.bump")),
		] },
		{ name: "ResortBeginAccounts", fields: [
			field("authority", "Signer"),
			field("config", "Owned<Config>", configSeeds(), hasOne("authority", NOT_AUTHORITY)),
			field("world", "Mutable<World>"),
			field("resort", "Mutable<Resort>"),
		] },
		{ name: "ResortClearAccounts", fields: [
			field("authority", "Signer"),
			field("config", "Owned<Config>", configSeeds(), hasOne("authority", NOT_AUTHORITY)),
			field("world", "Owned<World>"),
			field("resort", "Mutable<Resort>"),
			field("block", "Mutable<Block>"),
		] },
		{ name: "ResortAssignAccounts", fields: [
			field("authority", "Signer"),
			field("config", "Owned<Config>", configSeeds(), hasOne("authority", NOT_AUTHORITY)),
			field("resort", "Mutable<Resort>"),
			field("block", "Mutable<Block>"),
			field("previous", "Owned<Block>"),
		] },
		{ name: "ResortFinishAccounts", fields: [
			field("authority", "Signer"),
			field("config", "Owned<Config>", configSeeds(), hasOne("authority", NOT_AUTHORITY)),
			field("world", "Mutable<World>"),
			field("resort", "Owned<Resort>"),
		] },
		{ name: "DelegateResortAccounts", fields: [
			field("authority", "WritableSigner"),
			field("config", "Owned<Config>", configSeeds(), hasOne("authority", NOT_AUTHORITY)),
			field("resort", "Writable"),
			...delegation(),
		] },
	];
}
