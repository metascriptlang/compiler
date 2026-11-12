#![no_std]
use quasar_lang::prelude::*;

declare_id!("66666666666666666666666666666666666666666666");

#[program]
mod nested_quasar {
    use super::*;

    #[instruction(discriminator = [0xaf, 0xaf, 0x6d, 0x1f, 0x0d, 0x98, 0x9b, 0xed])]
    pub fn initialize(ctx: Ctx<Initialize>) -> Result<(), ProgramError> {
        let a = &mut ctx.accounts;
        a.config.admin = *a.admin.address();
        a.config.bump = ctx.bumps.config;
        a.counter.value = 0u64.into();
        a.counter.bump = ctx.bumps.counter;
        Ok(())
    }

    #[instruction(discriminator = [0x0b, 0x12, 0x68, 0x09, 0x68, 0xae, 0x3b, 0x21])]
    pub fn increment(ctx: Ctx<Increment>) -> Result<(), ProgramError> {
        let c = &mut ctx.accounts.counter;
        c.value = (c.value.get() + 1).into();
        Ok(())
    }

    #[instruction(discriminator = [0x17, 0x51, 0xfb, 0x54, 0x8a, 0xb7, 0xf0, 0xd6])]
    pub fn reset(ctx: Ctx<Reset>) -> Result<(), ProgramError> {
        ctx.accounts.counter.value = 0u64.into();
        Ok(())
    }
}

#[derive(Accounts)]
pub struct Initialize {
    #[account(mut)]
    pub admin: Signer,
    #[account(init, payer = admin, address = Config::seeds())]
    pub config: Account<Config>,
    #[account(init, payer = admin, address = Counter::seeds())]
    pub counter: Account<Counter>,
    pub system_program: Program<SystemProgram>,
}

#[derive(Accounts)]
pub struct Increment {
    pub admin: Signer,
    #[account(has_one(admin), address = Config::seeds())]
    pub config: Account<Config>,
    #[account(mut, address = Counter::seeds())]
    pub counter: Account<Counter>,
}

#[derive(Accounts)]
pub struct Reset {
    pub admin: Signer,
    #[account(has_one(admin), address = Config::seeds())]
    pub config: Account<Config>,
    #[account(mut, address = Counter::seeds())]
    pub counter: Account<Counter>,
}

#[account(discriminator = [0x9b, 0x0c, 0xaa, 0xe0, 0x1e, 0xfa, 0xcc, 0x82])]
#[seeds(b"config")]
pub struct Config {
    pub admin: Address,
    pub bump: u8,
    pub _pad: [u8; 7],
}

#[account(discriminator = [0xff, 0xb0, 0x04, 0xf5, 0xbc, 0xfd, 0x7c, 0x19])]
#[seeds(b"counter")]
pub struct Counter {
    pub value: u64,
    pub bump: u8,
    pub _pad: [u8; 7],
}
