#![no_std]
use quasar_lang::prelude::*;

declare_id!("B7ihZyoXZ1fwAY3TugkiFJ6SXkzJwMuQrxrekBaSmn32");

#[program]
mod hello_world_quasar {
    use super::*;

    #[instruction(discriminator = [0xdc, 0x3b, 0xcf, 0xec, 0x6c, 0xfa, 0x2f, 0x64])]
    pub fn init(ctx: Ctx<Init>) -> Result<(), ProgramError> {
        let counter = &mut ctx.accounts.counter;
        counter.value = 42u64.into();
        counter.bump = ctx.bumps.counter;
        Ok(())
    }
}

#[derive(Accounts)]
pub struct Init {
    #[account(mut)]
    pub payer: Signer,
    #[account(init, payer = payer, address = Counter::seeds())]
    pub counter: Account<Counter>,
    pub system_program: Program<SystemProgram>,
}

#[account(discriminator = [0xff, 0xb0, 0x04, 0xf5, 0xbc, 0xfd, 0x7c, 0x19])]
#[seeds(b"counter")]
pub struct Counter {
    pub value: u64,
    pub bump: u8,
    pub _pad: [u8; 7],
}
