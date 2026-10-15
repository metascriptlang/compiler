import { Discriminator, Pubkey, Signer, Writable, accountDiscriminator } from "std/solana";

export struct FarBase { owner: Signer; }
export struct FarDerived extends FarBase { refund: Writable; }

export struct FarKept { owner: Pubkey; }
export struct FarKeptChild extends FarKept { limit: uint64; }

export function discriminator(this typeof FarKeptChild): Discriminator {
	return @comptime { return accountDiscriminator("FarKeptChild"); };
}
