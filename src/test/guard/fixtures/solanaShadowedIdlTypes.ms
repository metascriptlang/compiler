import { Mutable, Owned, Pubkey, Signer, Writable, bump, leBytes, seeds } from "std/solana";

export struct EarlyInner { a: uint64; }
export struct EarlyHolder { inner: EarlyInner; }

export struct LateInner { a: uint64; }
export struct LateHolder { inner: LateInner[2]; }

export struct TwinInner { a: uint64; }
export struct TwinHolder { inner: TwinInner; }

export struct DeepInner { a: uint64; }
export struct DeepMiddle { inner: DeepInner; }
export struct DeepHolder { middle: DeepMiddle; }

export enum Mode { Idle, Busy }
export struct ModeHolder { mode: Mode; }

export enum Flag { First, Second, Third }
export struct FlagHolder { flags: BitSet<Flag>; }

export struct MovedInner { a: uint64; }
export struct Moved { inner: MovedInner; }

export struct KeyVault { owner: Pubkey; round: uint64; }
export struct KeyTake {
	owner: Signer;
	vault: Owned<KeyVault>;
	@seeds("pet", vault.owner) @bump pet: Writable;
}

export struct RoundVault { owner: Pubkey; round: uint64; }
export struct RoundTake {
	owner: Signer;
	vault: Mutable<RoundVault>;
	@seeds("pet", leBytes(vault.round)) @bump pet: Writable;
}
