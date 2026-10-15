import { Pubkey, Signer, Writable, address } from "std/solana";

export struct PinnedEarly { @address(Pubkey.zero()) authority: Signer; target: Writable; }
export struct PinnedLate { @address(Pubkey.zero()) authority: Signer; target: Writable; }
export struct PinnedTwin { @address(Pubkey.zero()) authority: Signer; target: Writable; }
export struct OpenRoot { authority: Signer; target: Writable; }
export struct PinnedLone { @address(Pubkey.zero()) authority: Signer; }
export struct PinnedAway { @address(Pubkey.zero()) authority: Signer; target: Writable; }
export struct PinnedRenamed { @address(Pubkey.zero()) authority: Signer; target: Writable; }
