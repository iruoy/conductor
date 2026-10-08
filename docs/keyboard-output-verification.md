# Scrollable transcript output verification (#45)

Scrollable tool calls, written content, results, diffs, and setup notes are native
Tab stops. Named `group` roles supply context without adding region landmarks.
There are no key handlers: scrolling, selection, and Tab navigation stay native.
The existing focus outline is inset to avoid clipping by the tool card.

## Browser check

Verified with Playwright WebKit 27.2 using server-rendered HTML from
`/runs/conductor-38-1` and the built app CSS (served from this branch on port
4045). HTML was loaded into the browser directly because WebKit navigation to
localhost timed out in this environment. A rendered `tool/1` edit fixture with
50 wide diff lines additionally exercised horizontal overflow.

- 34 scroll boxes checked for Shift+Tab/Tab entry and Tab exit.
- Computed keyboard focus outline: solid, 2px, inset 2px.
- PageDown scrolled all 23 vertically overflowing boxes.
- ArrowRight scrolled the horizontally overflowing diff fixture.
- axe `scrollable-region-focusable`: zero violations on these blocks.

To repeat manually in Safari (enable keyboard navigation in Safari settings):
open a run, expand its tool steps and setup notes, Tab into output and diff
blocks, scroll with arrows/PageDown, and exit with Tab and Shift+Tab. Check that
the outline remains visible, text can still be selected, and scrolling outside
the blocks still scrolls the transcript. Run axe with the tool steps expanded.

Component regression tests cover all tool block variants, error output, and
setup notes. `mix precommit` and `cd runner && pnpm test` pass.
