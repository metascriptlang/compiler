use zed_extension_api as zed;

struct MetaScriptExtension;

impl zed::Extension for MetaScriptExtension {
    fn new() -> Self {
        MetaScriptExtension
    }

    fn language_server_command(
        &mut self,
        _language_server_id: &zed::LanguageServerId,
        worktree: &zed::Worktree,
    ) -> zed::Result<zed::Command> {
        let path = worktree
            .which("msc")
            .ok_or_else(|| "msc not found on PATH. Install the MetaScript compiler.".to_string())?;

        Ok(zed::Command {
            command: path,
            args: vec!["lsp".to_string()],
            env: vec![],
        })
    }
}

zed::register_extension!(MetaScriptExtension);
