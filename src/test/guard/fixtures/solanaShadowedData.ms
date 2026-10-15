import {
	Delegated, Discriminator, Mutable, Owned, Program, Pubkey, Signer, Writable, accountDiscriminator, bump, constraint,
	hasOne, seeds,
} from "std/solana";

export struct EarlyVault { owner: Pubkey; limit: uint64; }
export struct EarlyTake { owner: Signer; @hasOne(owner) vault: Owned<EarlyVault>; }

export struct LateVault { owner: Pubkey; limit: uint64; }
export struct LateTake { owner: Signer; @constraint(vault.limit > 0) vault: Mutable<LateVault>; }

export struct ThinVault { limit: uint64; }
export struct ThinTake { owner: Signer; @hasOne(owner) vault: Owned<ThinVault>; }

export struct PlainVault { owner: Pubkey; limit: uint64; }
export struct PlainTake { owner: Signer; vault: Owned<PlainVault>; }

export struct TwinVault { owner: Pubkey; limit: uint64; }
export struct TwinTake { owner: Signer; @hasOne(owner) vault: Owned<TwinVault>; }

export struct HeldVault { owner: Pubkey; limit: uint64; }
export struct HeldTake { owner: Signer; @seeds("held", owner) @bump vault: Delegated<HeldVault>; }

export struct BaseVault { owner: Pubkey; limit: uint64; }
export struct HolderBase { owner: Signer; @hasOne(owner) vault: Owned<BaseVault>; }
export struct HolderChild extends HolderBase { target: Writable; }

export struct Oracle {}
export function id(this typeof Oracle): Pubkey { return Pubkey.zero(); }
export struct Feed { owner: Signer; oracle: Program<Oracle>; }

export function discriminator(this typeof EarlyVault): Discriminator {
	return @comptime { return accountDiscriminator("EarlyVault"); };
}
export function discriminator(this typeof LateVault): Discriminator {
	return @comptime { return accountDiscriminator("LateVault"); };
}
export function discriminator(this typeof ThinVault): Discriminator {
	return @comptime { return accountDiscriminator("ThinVault"); };
}
export function discriminator(this typeof PlainVault): Discriminator {
	return @comptime { return accountDiscriminator("PlainVault"); };
}
export function discriminator(this typeof TwinVault): Discriminator {
	return @comptime { return accountDiscriminator("TwinVault"); };
}
export function discriminator(this typeof HeldVault): Discriminator {
	return @comptime { return accountDiscriminator("HeldVault"); };
}
export function discriminator(this typeof BaseVault): Discriminator {
	return @comptime { return accountDiscriminator("BaseVault"); };
}
