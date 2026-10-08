const EDGE = 8
const PROGRAMMATIC_TOLERANCE = 1

export default {
  mounted() {
    this.following = true
    this.expectedTop = null

    this.onScroll = () => {
      // Collapsed panels have zero geometry, not a reader returning to the end.
      if (this.el.clientHeight === 0) return

      if (this.atEnd()) {
        this.following = true
        this.expectedTop = null
      } else if (
        this.expectedTop !== null &&
        Math.abs(this.el.scrollTop - this.expectedTop) <= PROGRAMMATIC_TOLERANCE
      ) {
        // Ignore a queued scroll event from our own scrollTop update.
        this.expectedTop = null
      } else {
        this.following = false
        this.expectedTop = null
      }
    }

    this.el.addEventListener("scroll", this.onScroll, {passive: true})
    this.resizeObserver = new ResizeObserver(() => this.follow())
    this.resizeObserver.observe(this.el)
    this.follow()
  },

  updated() {
    this.follow()
  },

  destroyed() {
    this.el.removeEventListener("scroll", this.onScroll)
    this.resizeObserver.disconnect()
  },

  atEnd() {
    const {scrollHeight, scrollTop, clientHeight} = this.el
    return scrollHeight - scrollTop - clientHeight <= EDGE
  },

  follow() {
    if (!this.following || this.el.clientHeight === 0) return

    const top = Math.max(0, this.el.scrollHeight - this.el.clientHeight)
    if (this.el.scrollTop !== top) {
      this.expectedTop = top
      this.el.scrollTop = top
    }
  }
}
