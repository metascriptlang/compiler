#![no_std]
use quasar_lang::prelude::*;

declare_id!("33333333333333333333333333333333333333333333");

#[derive(Seeds)]
#[seeds(b"vault", user: Address)]
pub struct VaultPda;

#[program]
mod vault_quasar {
    use super::*;

    #[instruction(discriminator = [0xf2, 0x23, 0xc6, 0x89, 0x52, 0xe1, 0xf2, 0xb6])]
    pub fn deposit(ctx: Ctx<Deposit>, amount: u64) -> Result<(), ProgramError> {
        ctx.accounts.system_program.transfer(&ctx.accounts.user, &ctx.accounts.vault, amount).invoke()
    }

    #[instruction(discriminator = [0xb7, 0x12, 0x46, 0x9c, 0x94, 0x6d, 0xa1, 0x22])]
    pub fn withdraw(ctx: Ctx<Withdraw>, amount: u64) -> Result<(), ProgramError> {
        let vault = ctx.accounts.vault.to_account_view();
        let user = ctx.accounts.user.to_account_view();
        let v = vault.lamports().checked_sub(amount).ok_or(ProgramError::InsufficientFunds)?;
        let u = user.lamports().checked_add(amount).ok_or(ProgramError::ArithmeticOverflow)?;
        set_lamports(vault, v);
        set_lamports(user, u);
        Ok(())
    }
}

#[derive(Accounts)]
pub struct Deposit {
    #[account(mut)]
    pub user: Signer,
    #[account(mut, address = VaultPda::seeds(user.address()))]
    pub vault: UncheckedAccount,
    pub system_program: Program<SystemProgram>,
}

#[derive(Accounts)]
pub struct Withdraw {
    #[account(mut)]
    pub user: Signer,
    #[account(mut, address = VaultPda::seeds(user.address()))]
    pub vault: UncheckedAccount,
}
