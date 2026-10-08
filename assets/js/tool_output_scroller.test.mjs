import assert from "node:assert/strict"
import test from "node:test"
import ToolOutputScroller from "./tool_output_scroller.mjs"

// A browser clamps scrollTop and queues/coalesces scroll events instead of
// synchronously firing them from its setter. Content growth alone does not
// produce a ResizeObserver notification for a fixed-height output viewport.
function browser(t) {
  const scrollEvents = new Set()
  const observers = new Set()
  const panels = new Set()

  class Output extends EventTarget {
    constructor({height = 1000, viewport = 200, hidden = false} = {}) {
      super()
      this.height = height
      this.viewport = viewport
      this.hidden = hidden
      this.top = 0
      this.scrollLeft = 29
      this.parentElement = {scrollTop: 420, scrollLeft: 17}
      this.listeners = new Set()
      this.writes = 0
    }

    get scrollHeight() { return this.hidden ? 0 : Math.max(this.height, this.viewport) }
    get clientHeight() { return this.hidden ? 0 : this.viewport }
    get scrollTop() { return this.top }
    set scrollTop(value) {
      this.writes++
      this.move(value)
    }

    move(value) {
      const next = Math.max(0, Math.min(value, this.scrollHeight - this.clientHeight))
      if (next !== this.top) {
        this.top = next
        scrollEvents.add(this)
      }
    }

    layout(changes) {
      Object.assign(this, changes)
      this.move(this.top)
    }

    addEventListener(type, callback, options) {
      super.addEventListener(type, callback, options)
      if (type === "scroll") this.listeners.add(callback)
    }

    removeEventListener(type, callback, options) {
      super.removeEventListener(type, callback, options)
      if (type === "scroll") this.listeners.delete(callback)
    }

    scrollIntoView() { assert.fail("must not scroll an ancestor") }
  }

  class ResizeObserverMock {
    constructor(callback) {
      this.callback = callback
      this.targets = new Set()
      this.disconnected = false
      observers.add(this)
    }
    observe(target) { this.targets.add(target) }
    disconnect() {
      this.targets.clear()
      this.disconnected = true
    }
  }

  const original = Object.getOwnPropertyDescriptor(globalThis, "ResizeObserver")
  Object.defineProperty(globalThis, "ResizeObserver", {configurable: true, value: ResizeObserverMock})
  t.after(() => {
    for (const hook of panels) hook.destroyed()
    if (original) Object.defineProperty(globalThis, "ResizeObserver", original)
    else delete globalThis.ResizeObserver
  })

  return {
    observers,
    mount(options) {
      const el = new Output(options)
      const hook = {...ToolOutputScroller, el}
      hook.mounted()
      panels.add(hook)
      return hook
    },
    destroy(hook) {
      hook.destroyed()
      panels.delete(hook)
    },
    flushScroll() {
      const pending = [...scrollEvents]
      scrollEvents.clear()
      for (const el of pending) el.dispatchEvent(new Event("scroll"))
    },
    resize(el, changes) {
      el.layout(changes)
      for (const observer of observers) {
        if (observer.targets.has(el)) observer.callback([{target: el}], observer)
      }
    },
  }
}

function atBottom(hook) {
  assert.equal(hook.el.scrollTop, hook.el.scrollHeight - hook.el.clientHeight)
}

function stream(hook, height) {
  hook.el.layout({height})
  hook.updated()
}

function pause(env, hook, top = 100) {
  env.flushScroll()
  hook.el.move(top)
  env.flushScroll()
  assert.equal(hook.el.scrollTop, top)
}

test("mount opens long output at its clamped end", t => {
  const env = browser(t)
  const hook = env.mount()
  assert.equal(hook.el.scrollTop, 800)
  env.flushScroll()
  atBottom(hook)
  assert.equal(hook.atEnd(), true)
})

test("streaming patches follow repeatedly without resize notifications", t => {
  const env = browser(t)
  const hook = env.mount()
  env.flushScroll()
  for (const height of [1100, 1500, 2200]) {
    stream(hook, height)
    atBottom(hook)
    env.flushScroll()
  }
})

test("queued programmatic scroll after content growth does not disengage follow", t => {
  const env = browser(t)
  const hook = env.mount()
  // The mount's scroll event arrives after a patch changed the geometry but
  // before updated() follows it. It must not be mistaken for reader input.
  hook.el.layout({height: 1200})
  env.flushScroll()
  hook.updated()
  atBottom(hook)
  stream(hook, 1600)
  env.flushScroll()
  stream(hook, 2000)
  atBottom(hook)
})

test("reader scroll wins over a still-queued programmatic scroll", t => {
  const env = browser(t)
  const hook = env.mount()
  hook.el.move(300)
  env.flushScroll()
  stream(hook, 1600)
  assert.equal(hook.el.scrollTop, 300)
})

test("reader scroll pauses a patch before its queued scroll event arrives", t => {
  const env = browser(t)
  const hook = env.mount()
  env.flushScroll()
  hook.el.move(300)
  stream(hook, 1600)
  assert.equal(hook.el.scrollTop, 300)
  env.flushScroll()
  stream(hook, 2000)
  assert.equal(hook.el.scrollTop, 300)
})

test("scrolling away pauses patches and resizing; scrolling back resumes", t => {
  const env = browser(t)
  const hook = env.mount()
  pause(env, hook)
  stream(hook, 1400)
  env.resize(hook.el, {viewport: 300})
  hook.follow()
  assert.equal(hook.el.scrollTop, 100)
  hook.el.move(hook.el.scrollHeight)
  env.flushScroll()
  stream(hook, 1800)
  atBottom(hook)
})

test("near-end tolerance resumes follow but reading well above the end does not", t => {
  const env = browser(t)
  const hook = env.mount()
  pause(env, hook, 700)
  assert.equal(hook.atEnd(), false)
  stream(hook, 1100)
  assert.equal(hook.el.scrollTop, 700)
  hook.el.move(hook.el.scrollHeight - hook.el.clientHeight - 4)
  env.flushScroll()
  assert.equal(hook.atEnd(), true)
  stream(hook, 1500)
  atBottom(hook)
})

test("horizontal scroll events do not disengage an otherwise following panel", t => {
  const env = browser(t)
  const hook = env.mount()
  env.flushScroll()
  hook.el.scrollLeft = 75
  hook.el.dispatchEvent(new Event("scroll"))
  stream(hook, 1300)
  atBottom(hook)
  assert.equal(hook.el.scrollLeft, 75)
})

test("empty and short output follow when they first become scrollable", t => {
  const env = browser(t)
  for (const height of [0, 80, 200]) {
    const hook = env.mount({height})
    assert.equal(hook.el.scrollTop, 0)
    assert.equal(hook.atEnd(), true)
    stream(hook, 600)
    atBottom(hook)
    env.flushScroll()
    stream(hook, 900)
    atBottom(hook)
  }
})

test("a followed panel can shrink to short output and grow again", t => {
  const env = browser(t)
  const hook = env.mount()
  env.flushScroll()
  stream(hook, 80)
  assert.equal(hook.el.scrollTop, 0)
  env.flushScroll()
  stream(hook, 900)
  atBottom(hook)
})

test("clamping a paused panel to the end on shrink allows subsequent following", t => {
  const env = browser(t)
  const hook = env.mount()
  pause(env, hook)
  stream(hook, 80)
  env.flushScroll()
  stream(hook, 900)
  atBottom(hook)
})

test("panels maintain independent follow state", t => {
  const env = browser(t)
  const reading = env.mount()
  const following = env.mount({height: 600})
  pause(env, reading)
  stream(reading, 1400)
  stream(following, 900)
  env.resize(reading.el, {viewport: 300})
  env.resize(following.el, {viewport: 150})
  assert.equal(reading.el.scrollTop, 100)
  atBottom(following)
  reading.el.move(reading.el.scrollHeight)
  env.flushScroll()
  stream(reading, 1800)
  atBottom(reading)
})

test("following only changes local vertical position, not horizontal or outer scroll", t => {
  const env = browser(t)
  const hook = env.mount()
  stream(hook, 1500)
  env.resize(hook.el, {viewport: 300})
  env.flushScroll()
  pause(env, hook)
  stream(hook, 1800)
  hook.el.move(hook.el.scrollHeight)
  env.flushScroll()
  hook.follow()
  assert.equal(hook.el.scrollLeft, 29)
  assert.deepEqual(hook.el.parentElement, {scrollTop: 420, scrollLeft: 17})
})

test("viewport resize keeps a following panel at the new end", t => {
  const env = browser(t)
  const hook = env.mount()
  env.flushScroll()
  for (const viewport of [100, 400, 1200, 200]) {
    env.resize(hook.el, {viewport})
    atBottom(hook)
    env.flushScroll()
  }
})

test("initially hidden output follows when opened and when reopened", t => {
  const env = browser(t)
  const hook = env.mount({hidden: true})
  assert.equal(hook.el.scrollTop, 0)
  env.resize(hook.el, {hidden: false})
  atBottom(hook)
  env.flushScroll()
  env.resize(hook.el, {hidden: true})
  stream(hook, 1600)
  env.flushScroll()
  env.resize(hook.el, {hidden: false})
  atBottom(hook)
})

test("resizing or reopening does not override a reader's paused position", t => {
  const env = browser(t)
  const hook = env.mount()
  pause(env, hook)
  env.resize(hook.el, {hidden: true})
  env.flushScroll()
  // Zero geometry while display:none is not the reader returning to the end.
  // Browsers may clamp the old position; do not demand its recovery on reopen.
  const position = hook.el.scrollTop
  env.resize(hook.el, {hidden: false, height: 1500})
  assert.equal(hook.el.scrollTop, position)
  stream(hook, 2000)
  assert.equal(hook.el.scrollTop, position)
})

test("destroy removes listeners and disconnects observation, including queued events", t => {
  const env = browser(t)
  const hook = env.mount()
  const other = env.mount()
  const observer = [...env.observers].find(item => item.targets.has(hook.el))
  assert.ok(observer, "the output viewport must be observed")
  assert.ok(hook.el.listeners.size > 0)
  env.destroy(hook)
  assert.equal(hook.el.listeners.size, 0)
  assert.equal(observer.disconnected, true)
  const writes = hook.el.writes
  env.flushScroll()
  env.resize(hook.el, {height: 1600, viewport: 100})
  assert.equal(hook.el.writes, writes)
  stream(other, 1600)
  atBottom(other)
})
