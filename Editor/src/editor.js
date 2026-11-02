// The Markdown editor Cecily Tasks shows in a web view: CodeMirror 6 with ProseMark, which hides
// Markdown's symbols except where the cursor is, and draws bullets and task boxes in their place.
// The text is never changed by showing it: what's stored is what was typed.
//
// The app talks to it through `window.cecily` (setText, getText, setTheme, setPlaceholder, focus,
// and the answers below) and hears back through the `cecily` message handler: {type: "ready"},
// {type: "change", text} and {type: "openLink", url}; {type: "findLinks", id, query}, answered by
// `linksFound`; {type: "resolveLinks", urls}, answered by `setLinkTitles`; and
// {type: "pastedURL", id, url}, answered by `titleLink`; and once `setTakesFiles(true)`,
// {type: "files", files: [{name, type, size, data}]}.
//
// Links to items and areas are `cecily-tasks://item/<id>` and `cecily-tasks://area/<id>`. Typing
// `[[` offers them by title, and each shows its target's current title, dimmed when the target is
// gone. A web address pasted on its own becomes a link with the page's title, once the app has it.
// Files pasted or dropped into the notes go to the app, to be kept beside the text, not in it:
// each file's contents as base64, or none when it's bigger than the app keeps.

import { EditorView, placeholder, Decoration, WidgetType } from "@codemirror/view"
import { EditorState, Annotation, Compartment, StateField, StateEffect, RangeSetBuilder, Prec } from "@codemirror/state"
import { markdown } from "@codemirror/lang-markdown"
import { syntaxHighlighting, HighlightStyle, indentUnit, syntaxTree } from "@codemirror/language"
import { GFM } from "@lezer/markdown"
import { tags } from "@lezer/highlight"
import {
  prosemarkBasicSetup, prosemarkMarkdownSyntaxExtensions, clickLinkHandler, generalSyntaxHighlights, baseTheme, codeFenceTheme, markdownTags,
} from "@prosemark/core"

const started = performance.now()

function post(message) {
  window.webkit?.messageHandlers?.cecily?.postMessage(message)
}

// The Markdown's text styles, in place of ProseMark's. The rest of the look is in editor.html.
const highlights = syntaxHighlighting(HighlightStyle.define([
  { tag: tags.heading1, fontSize: "1.3em", fontWeight: "600" },
  { tag: tags.heading2, fontSize: "1.15em", fontWeight: "600" },
  { tag: [tags.heading3, tags.heading4, tags.heading5, tags.heading6], fontWeight: "600" },
  { tag: markdownTags.headerMark, color: "var(--pm-header-mark-color)", fontWeight: "400" },
  { tag: tags.strong, fontWeight: "bold" },
  { tag: tags.emphasis, fontStyle: "italic" },
  { tag: tags.strikethrough, textDecoration: "line-through", color: "var(--secondary)" },
  { tag: [tags.meta, tags.comment, markdownTags.listMark, markdownTags.escapeMark], color: "var(--pm-muted-color)" },
  { tag: markdownTags.linkURL, color: "var(--pm-link-color)", cursor: "pointer" },
]))

const fromApp = Annotation.define()
const placeholderSetting = new Compartment()

// Questions for the app, each answered by its id.
let lastRequest = 0
const waiting = new Map()

function ask(message) {
  const id = ++lastRequest
  return new Promise((resolve) => {
    waiting.set(id, resolve)
    post({ ...message, id })
  })
}

function answer(id, value) {
  waiting.get(id)?.(value)
  waiting.delete(id)
}

// Items and areas offered after `[[`, found by the app. Choosing one replaces the `[[` and what was
// typed after it, and the `]]` the editor closed it with, by a link to it.
function itemLinks(context) {
  const typed = context.matchBefore(/\[\[[^\]\n]*$/)
  if (!typed) return null
  return ask({ type: "findLinks", query: typed.text.slice(2) }).then((targets) => ({
    from: typed.from + 2,
    filter: false,
    options: targets.map((target) => ({
      label: target.title,
      detail: target.place,
      apply(view, _completion, from, to) {
        const end = view.state.sliceDoc(to, to + 2) === "]]" ? to + 2 : to
        view.dispatch({ changes: { from: from - 2, to: end, insert: target.markdown }, selection: { anchor: from - 2 + target.markdown.length } })
      },
    })),
  }))
}

const itemLinkPattern = /cecily-tasks:\/\/(?:item|area)\/[0-9A-Fa-f-]{36}/g

// The current title of each item or area linked to, and whether it's gone, by link URL.
const setLinkTitles = StateEffect.define()
const linkTitles = StateField.define({
  create: () => ({}),
  update(titles, transaction) {
    for (const effect of transaction.effects) if (effect.is(setLinkTitles)) titles = { ...titles, ...effect.value }
    return titles
  },
})

let asked = new Set()

// Asks the app for the titles of the links it hasn't been asked about, or of every link.
function resolveLinks(state, everything = false) {
  if (everything) asked = new Set()
  const urls = [...new Set(state.doc.toString().match(itemLinkPattern) ?? [])].filter((url) => !asked.has(url))
  if (urls.length === 0) return
  urls.forEach((url) => asked.add(url))
  post({ type: "resolveLinks", urls })
}

class LinkTitle extends WidgetType {
  constructor(text, isGone, url) {
    super()
    this.text = text
    this.isGone = isGone
    this.url = url
  }

  eq(other) {
    return other.text === this.text && other.isGone === this.isGone && other.url === this.url
  }

  toDOM() {
    const span = document.createElement("span")
    span.className = this.isGone ? "cm-item-link cm-item-link-gone" : "cm-item-link"
    span.textContent = this.text
    span.dataset.url = this.url
    return span
  }

  ignoreEvent() {
    return false
  }
}

// Each link to an item or area away from the cursor shows its target's current title.
function itemLinkDecorations(state) {
  const titles = state.field(linkTitles)
  const builder = new RangeSetBuilder()
  syntaxTree(state).iterate({
    enter(node) {
      if (node.name !== "Link") return
      let labelFrom = null
      let labelTo = null
      let url = null
      for (let child = node.node.firstChild; child; child = child.nextSibling) {
        if (child.name === "LinkMark") {
          const mark = state.sliceDoc(child.from, child.to)
          if (mark === "[") labelFrom = child.to
          else if (mark === "]") labelTo = child.from
        } else if (child.name === "URL") {
          url = state.sliceDoc(child.from, child.to)
        }
      }
      const target = url && titles[url]
      const touched = state.selection.ranges.some((range) => range.from <= node.to && range.to >= node.from)
      if (target && !touched && labelFrom !== null && labelTo !== null && labelTo > labelFrom) {
        const text = target.title || state.sliceDoc(labelFrom, labelTo)
        builder.add(labelFrom, labelTo, Decoration.replace({ widget: new LinkTitle(text, target.isGone, url) }))
      }
      return false
    },
  })
  return builder.finish()
}

const itemLinkTitles = StateField.define({
  create: itemLinkDecorations,
  update(decorations, transaction) {
    const changed =
      transaction.docChanged ||
      transaction.selection ||
      transaction.effects.some((effect) => effect.is(setLinkTitles)) ||
      syntaxTree(transaction.state) !== syntaxTree(transaction.startState)
    return changed ? itemLinkDecorations(transaction.state) : decorations
  },
  provide: (field) => EditorView.decorations.from(field),
})

// A click on a link to an item or area opens it, unless it's gone.
const clickItemLinks = Prec.highest(
  EditorView.domEventHandlers({
    mousedown(event) {
      const link = event.target instanceof Element ? event.target.closest(".cm-item-link") : null
      if (!link) return false
      event.preventDefault()
      if (!link.classList.contains("cm-item-link-gone")) post({ type: "openLink", url: link.dataset.url })
      return true
    },
  }),
)

// Web addresses pasted on their own, kept in place through edits until the app has their titles.
const addPaste = StateEffect.define()
const removePaste = StateEffect.define()
const pastes = StateField.define({
  create: () => [],
  update(list, transaction) {
    list = list.map((paste) => ({ ...paste, from: transaction.changes.mapPos(paste.from, 1), to: transaction.changes.mapPos(paste.to, -1) }))
    for (const effect of transaction.effects) {
      if (effect.is(addPaste)) list = [...list, effect.value]
      if (effect.is(removePaste)) list = list.filter((paste) => paste.id !== effect.value)
    }
    return list
  },
})

function isWebAddress(text) {
  if (!text || /\s/.test(text.trim())) return false
  try {
    const url = new URL(text.trim())
    return (url.protocol === "http:" || url.protocol === "https:") && url.host !== ""
  } catch {
    return false
  }
}

let takesFiles = false
const largestFile = 50 * 1024 * 1024

function readFile(file) {
  return new Promise((resolve) => {
    const base = { name: file.name || "Pasted file", type: file.type, size: file.size, data: null }
    if (file.size > largestFile) return resolve(base)
    const reader = new FileReader()
    reader.onload = () => resolve({ ...base, data: String(reader.result).replace(/^data:[^,]*,/, "") })
    reader.onerror = () => resolve(base)
    reader.readAsDataURL(file)
  })
}

function sendFiles(event, fileList) {
  const files = [...(fileList ?? [])]
  if (!takesFiles || files.length === 0) return false
  event.preventDefault()
  Promise.all(files.map(readFile)).then((read) => post({ type: "files", files: read }))
  return true
}

const fileDrops = EditorView.domEventHandlers({
  paste(event) {
    return sendFiles(event, event.clipboardData?.files)
  },
  drop(event) {
    return sendFiles(event, event.dataTransfer?.files)
  },
})

const pasteWebLinks = EditorView.domEventHandlers({
  paste(event, view) {
    const text = event.clipboardData?.getData("text/plain")
    if (!isWebAddress(text)) return false
    event.preventDefault()
    const url = text.trim()
    const selection = view.state.selection.main
    if (!selection.empty) {
      const label = view.state.sliceDoc(selection.from, selection.to)
      const link = `[${label}](${url})`
      view.dispatch({ changes: { from: selection.from, to: selection.to, insert: link }, selection: { anchor: selection.from + link.length } })
      return true
    }
    const id = ++lastRequest
    view.dispatch({
      changes: { from: selection.from, insert: url },
      selection: { anchor: selection.from + url.length },
      effects: addPaste.of({ id, url, from: selection.from, to: selection.from + url.length }),
    })
    post({ type: "pastedURL", id, url })
    return true
  },
})

const view = new EditorView({
  parent: document.getElementById("editor"),
  state: EditorState.create({
    doc: "",
    extensions: [
      markdown({ extensions: [GFM, prosemarkMarkdownSyntaxExtensions] }),
      prosemarkBasicSetup(),
      highlights,
      generalSyntaxHighlights,
      baseTheme,
      codeFenceTheme,
      indentUnit.of("\t"),
      placeholderSetting.of([]),
      clickLinkHandler.of((url) => post({ type: "openLink", url })),
      EditorState.languageData.of(() => [{ autocomplete: itemLinks }]),
      linkTitles,
      itemLinkTitles,
      pastes,
      fileDrops,
      pasteWebLinks,
      clickItemLinks,
      EditorView.contentAttributes.of({ "aria-label": "Notes", autocapitalize: "sentences", autocorrect: "on", spellcheck: "true" }),
      EditorView.updateListener.of((update) => {
        if (update.docChanged && !update.transactions.some((transaction) => transaction.annotation(fromApp))) {
          post({ type: "change", text: update.state.doc.toString() })
        }
        if (update.docChanged) resolveLinks(update.state)
      }),
    ],
  }),
})

window.cecily = {
  setText(text) {
    if (text === view.state.doc.toString()) return
    view.dispatch({ changes: { from: 0, to: view.state.doc.length, insert: text }, annotations: fromApp.of(true) })
    resolveLinks(view.state, true)
  },
  getText() {
    return view.state.doc.toString()
  },
  /// Colours, as CSS, the body text's size in points, and whether the first line is a title.
  setTheme(theme) {
    const root = document.documentElement.style
    for (const name of ["label", "secondary", "dimmed", "accent", "selection", "separator", "fill"]) {
      if (theme[name]) root.setProperty(`--${name}`, theme[name])
    }
    if (theme.fontSize) root.setProperty("--font-size", `${theme.fontSize}px`)
    document.getElementById("editor").classList.toggle("title-line", !!theme.titleLine)
  },
  /// What shows while there's no text, or nothing for an empty string.
  setPlaceholder(text) {
    view.dispatch({ effects: placeholderSetting.reconfigure(text ? placeholder(text) : []) })
  },
  focus() {
    view.focus()
  },
  /// Whether files pasted or dropped go to the app.
  setTakesFiles(value) {
    takesFiles = value
  },
  /// The items and areas found for a `findLinks` question: [{title, place, markdown}].
  linksFound(id, targets) {
    answer(id, targets)
  },
  /// Links' targets as they are now: {url: {title, isGone}}.
  setLinkTitles(titles) {
    view.dispatch({ effects: setLinkTitles.of(titles) })
  },
  /// Replaces a pasted web address by `link`, if it's still there as it was pasted; nil leaves it.
  titleLink(id, link) {
    const paste = view.state.field(pastes).find((paste) => paste.id === id)
    if (!paste) return
    const isIntact = view.state.sliceDoc(paste.from, paste.to) === paste.url
    view.dispatch({
      changes: link && isIntact ? { from: paste.from, to: paste.to, insert: link } : [],
      effects: removePaste.of(id),
    })
  },
}

post({ type: "ready", milliseconds: Math.round(performance.now() - started) })
