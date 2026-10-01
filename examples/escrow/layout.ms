import { Discriminator, ProgramError, Pubkey, accountDiscriminator } from "std/solana";

export enum EscrowOp {
	Make,
	Take,
	Refund,
}

export struct Escrow {
	seed: uint64;
	maker: Pubkey;
	mintA: Pubkey;
	mintB: Pubkey;
	receive: uint64;
	bump: uint8;
}

export function discriminator(this typeof Escrow): Discriminator {
	return @comptime { return accountDiscriminator("Escrow"); };
}

export struct MakeArgs {
	seed: uint64;
	deposit: uint64;
	receive: uint64;
}

export enum EscrowError {
	ZeroAmount,
}

export converter escrowError(error: EscrowError): ProgramError {
	return ProgramError.userError(error as uint32);
}
