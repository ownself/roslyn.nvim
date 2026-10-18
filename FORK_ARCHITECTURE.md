# Fork integration boundaries

The fork adopts upstream commit `7d8c166` without changing these baseline modules:

- `lua/roslyn/sln/discovery.lua`
- `lua/roslyn/target.lua`
- `lua/roslyn/store.lua`

Do not monkey-patch these modules or maintain another copy of their full implementations.
The plugin entry points explicitly opt into `roslyn.fork.*`.

## Fork-owned modules

- `fork/discovery.lua`: nearest matching ancestor; cwd-bounded ordinary solution search;
  all projects at the nearest project level. Broad search delegates to upstream.
- `fork/target.lua`: containment/ignore filtering, session-selection validation,
  explicit solution/project ambiguity, asynchronous selection and waiting callbacks.
  Uses upstream `remember`/`consume` for initialization handoff. Never resolves the
  currently focused buffer again during `on_init`.
- `fork/store.lua`: session selection memory and client resolved targets. Keeps the
  upstream solution-only client API synchronized, but never reads its global
  selected solution as a fallback. `roslyn_nvim_selected_target` remains a UI value.
- `fork/commands.lua`: configuration selection, context display and Unity filter generation.

## Integration points to review when updating upstream

- `lsp/roslyn.lua`: fork root callback, cached initialization and client cleanup.
- `lua/roslyn/lsp/on_init.lua`: record solution/project initialization through fork store.
- `plugin/roslyn.lua`: synchronize structured UI state from the attached client;
  keep enabling the LSP in setup, after configuration, rather than at plugin load.
- `lua/roslyn/commands.lua`: fork discovery for target/start and register fork commands.
- `lua/roslyn/health.lua`: structured target display.

The old `sln/utils.lua`, `sln/customized_utils.lua` and their obsolete prediction
unit tests are removed. Automatic and manual discovery now share one search policy.
Internal consumers of the old resolved-target store API must use `roslyn.fork.store`.

## Deliberate behavior

- Apply ignore and project-containment checks even to a single solution.
- Match any nearest-level csproj, not an arbitrary first csproj (important for Unity).
- Prompt when ambiguity remains; cancellation does not initialize a nil-root client.
- Remember a valid selected target across client restarts within the session.
- Revalidate selections against the current filtered candidates.
- Manual solution initialization also updates session memory.
- Same-root solutions/filters represent alternative contexts, not concurrent clients.
- Broad search retains upstream traversal/root policy; cwd restriction applies to
  ordinary upward solution search, not broad search or project ancestor discovery.

## Verification

Portable checks (no LuaRocks/Busted required):

```sh
nvim --headless -u NONE -l test/fork_smoke.lua
```

This compiles all Lua sources and checks search/selection/state behavior, actual
Neovim LSP startup/reuse with the mock transport, and Unity JSON generation.

The normal `nvim-test` integration suite additionally requires the dependencies
specified by `Makefile` and a compatible Unix runner. Run it in CI before publishing.

## Known follow-up limitations

- A root identifies one selected context; concurrent same-root Editor/Player clients
  need a richer client identity/reuse policy and are not added here.
- Solution parsing still uses upstream line-based parsers, not a full MSBuild or
  JSON project-membership evaluator.
- Source-generated buffers retain upstream's first-Roslyn-client fallback.
- Build configuration switching retains the existing workflow; verify actual server
  environment propagation separately when changing Neovim/client restart behavior.
