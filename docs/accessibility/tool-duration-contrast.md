# Tool execution duration contrast (#44)

Tool headers have an opaque `bg-base-100` background in all states. Durations now use
`text-fg-secondary` rather than `text-fg-tertiary`, retaining their small, normal-weight,
tabular-number styling and secondary hierarchy without changing the global palette.

Computed browser colors and WCAG contrast ratios:

| Theme | Background | Previous foreground / ratio | New foreground / ratio |
| --- | --- | --- | --- |
| Light | `#FFFFFF` | `#8A8C91` / 3.36:1 | `#5E6168` / 6.20:1 |
| Dark | `#1A1B1F` | `#7D8087` / 4.35:1 | `#A0A3AA` / 6.81:1 |

## Verification

Reproduced `/runs/conductor-38-1` against the local development database. The original
server on port 4000 failed axe-core 4.13.0's `color-contrast` rule in both themes.
The feature branch was served on port 4001 with background workers disabled to avoid
interfering with the existing server's runs.

Using headless Chromium, opened transcript `details` elements, set the root
`data-theme` to `light` and then `dark`, and ran:

```javascript
await axe.run(
  {include: ['[data-tool-duration]']},
  {runOnly: ['color-contrast']}
)
```

After the change, all 26 duration spans on the reproduced page passed in each theme,
with zero violations or incomplete results. The transcript includes successful and
failed tool calls. Separately rendered `tool/1` fixtures for idle, running, done,
failed, exit 0, and exit 1 states passed the same browser check in both themes
(6 passes per theme, zero violations or incomplete results).

Regression tests cover the duration's foreground class and opaque background in all
six states, plus WCAG relative-luminance calculations against the actual light and
dark theme tokens. Run them with:

```sh
mix test test/conductor_web/components/run_components_test.exs
```
