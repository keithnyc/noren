# Agents

- **Installing Noren for someone?** Follow [`INSTALL.md`](INSTALL.md). It is a
  step-by-step runbook that says where to stop and ask the user.
- **Writing a site script** — per-site CSS or JS that changes how one website
  behaves — read [`skills/noren-site/SKILL.md`](skills/noren-site/SKILL.md). It
  carries the rules, the safety model and the workflow. Claude Code picks it up
  as a skill; other agents should read it as a document.
- **Changing Noren's code?** Read [`CLAUDE.md`](CLAUDE.md), then
  [`DEVELOPMENT.md`](DEVELOPMENT.md).

Whatever you are doing: Noren's own source, plugin directory and
`~/.config/noren/*.json` are not yours to edit on a user's behalf unless they
asked for exactly that. Site scripts never need it.
