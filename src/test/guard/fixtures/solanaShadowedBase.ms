import { Discriminator, Pubkey, Signer, Writable, accountDiscriminator, address } from "std/solana";
import { FarBase } from "./solanaFarBase";

export struct PinnedEarly { @address(Pubkey.zero()) authority: Signer; }
export struct EarlyChild extends PinnedEarly { target: Writable; }

export struct PinnedLate { @address(Pubkey.zero()) authority: Signer; }
export struct LateChild extends PinnedLate { target: Writable; }

export struct OpenBase { authority: Signer; }
export struct OpenChild extends OpenBase { target: Writable; }

export struct PinnedRoot { @address(Pubkey.zero()) authority: Signer; }
export struct PinnedMiddle extends PinnedRoot { payer: Signer; }
export struct PinnedLeaf extends PinnedMiddle { target: Writable; }

export struct Decoy { authority: Signer; }
export struct PinnedNamed { @address(Pubkey.zero()) authority: Signer; }
export struct NamedChild extends PinnedNamed { target: Writable; }

export struct Borrowed extends FarBase { target: Writable; }

export struct KeptBase { owner: Pubkey; }
export struct KeptChild extends KeptBase { limit: uint64; }

export function discriminator(this typeof KeptChild): Discriminator {
	return @comptime { return accountDiscriminator("KeptChild"); };
}
