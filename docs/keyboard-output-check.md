# Tool-output keyboard accessibility check

On a run transcript with long tool output, expand any collapsed entries. In Safari,
enable keyboard navigation (Tab highlights each item) if it is disabled in browser
settings.

- Tab into multiline tool calls, written file content, output, and edit diffs.
- Check that the blue focus outline is visible inside the block, including at its
  clipped edges, in light and dark themes.
- Use ArrowDown/PageDown to scroll tall output. Use ArrowRight on a wide diff.
- Tab and Shift+Tab must leave the block normally. Text selection and ordinary
  transcript scrolling should still work.
- Run axe's `scrollable-region-focusable` rule against the expanded blocks.

Verification for #45: Playwright WebKit checked 33 transcript blocks from
`conductor-38-1` plus a rendered `tool/1` diff fixture with tall, wide content.
Keyboard entry/exit and the computed 2px inset focus outline passed. 23 vertically
scrollable blocks and one horizontally scrollable diff scrolled via keyboard.
Axe reported zero `scrollable-region-focusable` violations for these blocks.
WebKit verification is not a manual test of Safari's browser settings.

Component tests cover named, non-landmark tab stops for multiline calls, writes,
diffs, completed/error/streaming output, and transcript notes that share the same
scroll-box styling. No key handlers or changes to scroll/selection behavior are
needed: scrolling and tab navigation remain native browser behavior.
