;(function () {
  'use strict'

  window.__foxInspectMode = false
  window.__foxInspectEnabled = true
  window.__foxSentPending = false
  window.__foxPopupOpen = false
  window.__foxHighlightedEl = null
  window.__foxSelectedSessionId = null
  window.__foxSessions = []
  window.__foxSessionsError = false

  var overlayStyle = document.createElement('style')
  overlayStyle.textContent = [
    '#__fox-overlay{position:fixed;bottom:16px;right:16px;z-index:2147483647;font-family:system-ui,sans-serif;font-size:13px;pointer-events:none}',
    '#__fox-widget{background:#1e1e1e;color:#e0e0e0;padding:8px 12px;border-radius:8px;box-shadow:0 4px 20px rgba(0,0,0,.4);display:flex;align-items:center;gap:10px;pointer-events:auto}',
    '#__fox-widget .__fox-label{font-size:12px;font-weight:500;color:#888}',
    '#__fox-toggle{background:#3b82f6;color:#fff;border:none;padding:4px 10px;border-radius:4px;cursor:pointer;font-size:12px;font-family:inherit}',
    '#__fox-toggle:hover{background:#2563eb}',
    '#__fox-toggle.__fox-active{background:#ef4444}',
    '#__fox-toggle.__fox-active:hover{background:#dc2626}',
    '.__fox-highlight{outline:2px solid #3b82f6!important;outline-offset:1px!important}',
    '#__fox-popup{position:fixed;background:#1e1e1e;color:#e0e0e0;padding:12px;border-radius:8px;box-shadow:0 4px 20px rgba(0,0,0,.5);z-index:2147483647;min-width:320px;max-width:420px;pointer-events:auto;font-family:system-ui,sans-serif}',
    '#__fox-popup .__fox-selector{font-family:monospace;font-size:11px;color:#888;background:#2a2a2a;padding:4px 8px;border-radius:4px;word-break:break-all;margin-bottom:8px;max-height:80px;overflow:auto}',
    '#__fox-popup .__fox-tag{font-size:12px;color:#aaa;margin-bottom:8px}',
    '#__fox-popup .__fox-tag span{color:#3b82f6}',
    '#__fox-popup textarea{width:100%;background:#2a2a2a;color:#e0e0e0;border:1px solid #444;border-radius:4px;padding:6px 8px;font-size:12px;resize:vertical;min-height:60px;box-sizing:border-box;font-family:inherit}',
    '#__fox-popup textarea:focus{border-color:#3b82f6;outline:none}',
    '#__fox-popup .__fox-session-row{display:flex;align-items:center;gap:6px;margin-bottom:8px;font-size:11px}',
    '#__fox-popup .__fox-session-row label{color:#888;white-space:nowrap}',
    '#__fox-popup .__fox-session-picker{background:#2a2a2a;color:#e0e0e0;border:1px solid #444;border-radius:4px;padding:3px 6px;font-size:11px;font-family:inherit;flex:1;cursor:pointer}',
    '#__fox-popup .__fox-session-picker:focus{border-color:#3b82f6;outline:none}',
    '#__fox-popup .__fox-session-picker.__fox-error{border-color:#ef4444}',
    '#__fox-popup .__fox-session-picker option{background:#1e1e1e;color:#e0e0e0}',
    '#__fox-popup .__fox-actions{display:flex;justify-content:flex-end;gap:8px;margin-top:8px}',
    '#__fox-popup button.__fox-send{background:#3b82f6;color:#fff;border:none;padding:6px 14px;border-radius:4px;cursor:pointer;font-size:12px;font-family:inherit}',
    '#__fox-popup button.__fox-send:hover{background:#2563eb}',
    '#__fox-popup button.__fox-cancel{background:transparent;color:#888;border:1px solid #444;padding:6px 14px;border-radius:4px;cursor:pointer;font-size:12px;font-family:inherit}',
    '#__fox-popup button.__fox-cancel:hover{color:#aaa;border-color:#666}',
  ].join('\n')

  var overlay = document.createElement('div')
  overlay.id = '__fox-overlay'
  overlay.innerHTML =
    '<div id="__fox-widget">' +
    '<span class="__fox-label">OpenFox</span>' +
    '<button id="__fox-toggle">Send feedback</button>' +
    '</div>'

  var toggleBtn

  function setInspectMode(enabled) {
    window.__foxInspectMode = enabled
    if (toggleBtn) {
      toggleBtn.textContent = enabled ? 'Exit inspect' : 'Send feedback'
      toggleBtn.classList.toggle('__fox-active', enabled)
    }
  }

  function clearHighlights() {
    if (window.__foxHighlightedEl) {
      window.__foxHighlightedEl.classList.remove('__fox-highlight')
      window.__foxHighlightedEl = null
    }
  }

  function generateXPath(el) {
    if (!el || el.nodeType !== Node.ELEMENT_NODE) return ''
    var parts = []
    while (el && el.nodeType === Node.ELEMENT_NODE && el !== document.documentElement) {
      var index = 1
      var sibling = el.previousSibling
      while (sibling) {
        if (sibling.nodeType === Node.ELEMENT_NODE && sibling.nodeName === el.nodeName) index++
        sibling = sibling.previousSibling
      }
      parts.unshift(el.nodeName.toLowerCase() + '[' + index + ']')
      el = el.parentNode
    }
    return '/' + parts.join('/')
  }

  function stripSvgAndGetText(el) {
    try {
      var clone = el.cloneNode(true)
      var svgs = clone.querySelectorAll('svg')
      for (var i = 0; i < svgs.length; i++) {
        svgs[i].remove()
      }
      var text = (clone.textContent || '').replace(/\s+/g, ' ').trim()
      return text.slice(0, 500) || null
    } catch {
      return null
    }
  }

  function buildElementData(el) {
    var attrs = {}
    if (el.attributes) {
      for (var i = 0; i < el.attributes.length; i++) {
        var attr = el.attributes[i]
        if (attr.name !== 'class' && attr.name !== 'id') {
          attrs[attr.name] = attr.value
        }
      }
    }
    var rect = el.getBoundingClientRect()
    var tagName = el.tagName ? el.tagName.toLowerCase() : ''
    return {
      tag: tagName,
      id: el.id || null,
      className: (typeof el.className === 'string' ? el.className : '') || null,
      xpath: generateXPath(el),
      text: (el.innerText || '').slice(0, 500) || null,
      textContent: stripSvgAndGetText(el),
      outerHTML: (el.outerHTML || '').slice(0, 1000) || '',
      rect: { x: rect.left, y: rect.top, width: rect.width, height: rect.height },
      attributes: attrs,
    }
  }

  function showPopup(el, x, y) {
    var existing = document.getElementById('__fox-popup')
    if (existing) existing.remove()

    window.__foxPopupOpen = true
    var data = buildElementData(el)
    var viewportWidth = window.innerWidth
    var viewportHeight = window.innerHeight

    var left = x + 10
    var top = y + 10
    if (left + 360 > viewportWidth) left = x - 370
    if (top + 320 > viewportHeight) top = y - 330
    if (left < 8) left = 8
    if (top < 8) top = 8

    var popup = document.createElement('div')
    popup.id = '__fox-popup'
    popup.style.left = left + 'px'
    popup.style.top = top + 'px'

    var tagDisplay = data.tag + (data.id ? '#' + data.id : data.className ? '.' + data.className.split(' ')[0] : '')

    // Build session options
    var sessionOpts = '<option value="">Select session...</option>'
    for (var i = 0; i < window.__foxSessions.length; i++) {
      var s = window.__foxSessions[i]
      var sel = s.id === window.__foxSelectedSessionId ? ' selected' : ''
      sessionOpts += '<option value="' + s.id + '"' + sel + '>' + (s.title || s.id) + '</option>'
    }

    popup.innerHTML =
      '<div class="__fox-tag">Element: <span>' +
      tagDisplay +
      '</span></div>' +
      '<div class="__fox-selector">' +
      data.xpath +
      '</div>' +
      '<textarea placeholder="What\'s wrong with this element?" id="__fox-feedback-textarea"></textarea>' +
      '<div class="__fox-session-row">' +
      '<label>Session:</label>' +
      '<select class="__fox-session-picker" id="__fox-popup-session-picker">' +
      sessionOpts +
      '</select>' +
      '</div>' +
      '<div class="__fox-actions">' +
      '<button class="__fox-cancel">Cancel</button>' +
      '<button class="__fox-send">Send to Agent</button>' +
      '</div>'

    document.body.appendChild(popup)

    var textarea = popup.querySelector('#__fox-feedback-textarea')
    var picker = popup.querySelector('#__fox-popup-session-picker')
    textarea.focus()

    // Sync picker changes back to global state
    picker.addEventListener('change', function () {
      window.__foxSelectedSessionId = picker.value || null
      try {
        sessionStorage.setItem('__foxSelectedSessionId', picker.value)
      } catch {}
    })

    textarea.addEventListener('keydown', function (ke) {
      if (ke.key === 'Enter' && !ke.shiftKey) {
        ke.preventDefault()
        popup.querySelector('.__fox-send').click()
      }
    })

    popup.querySelector('.__fox-cancel').addEventListener('click', function (e) {
      e.preventDefault()
      e.stopPropagation()
      window.__foxPopupOpen = false
      popup.remove()
    })

    popup.querySelector('.__fox-send').addEventListener('click', function (e) {
      e.preventDefault()
      e.stopPropagation()
      if (window.__foxSentPending) return

      var sessionId = picker.value
      if (!sessionId) {
        picker.classList.add('__fox-error')
        setTimeout(function () {
          picker.classList.remove('__fox-error')
        }, 2000)
        return
      }

      window.__foxSentPending = true
      setTimeout(function () {
        window.__foxSentPending = false
      }, 3000)
      var annotation = textarea.value.trim()
      window.__foxPopupOpen = false
      popup.remove()
      clearHighlights()
      setInspectMode(false)

      fetch('/__openfox_feedback', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          sessionId: sessionId,
          element: data,
          annotation: annotation,
          pageUrl: window.location.href,
        }),
      }).catch(function (err) {
        console.error('Failed to send feedback:', err)
      })
    })

    popup.addEventListener('click', function (e) {
      e.stopPropagation()
    })

    document.addEventListener('keydown', function escHandler(e) {
      if (e.key === 'Escape') {
        window.__foxPopupOpen = false
        popup.remove()
        clearHighlights()
        setInspectMode(false)
        document.removeEventListener('keydown', escHandler)
      }
    })
  }

  document.addEventListener(
    'mouseover',
    function (e) {
      if (!window.__foxInspectMode || window.__foxPopupOpen) return
      if (e.target === document.documentElement || e.target === document.body) return
      if (overlay.contains(e.target)) return
      clearHighlights()
      e.target.classList.add('__fox-highlight')
      window.__foxHighlightedEl = e.target
    },
    true,
  )

  document.addEventListener(
    'click',
    function (e) {
      if (!window.__foxInspectMode) return
      if (overlay.contains(e.target)) return
      if (document.getElementById('__fox-popup')) return

      e.preventDefault()
      e.stopPropagation()
      var el = window.__foxHighlightedEl
      if (!el) return
      showPopup(el, e.clientX, e.clientY)
    },
    true,
  )

  document.addEventListener('keydown', function (e) {
    if (e.key === 'Escape' && window.__foxInspectMode) {
      clearHighlights()
      setInspectMode(false)
    }
    if (e.ctrlKey && e.shiftKey && e.key === 'X') {
      e.preventDefault()
      if (window.__foxInspectMode) clearHighlights()
      setInspectMode(!window.__foxInspectMode)
    }
  })

  function fetchSessions() {
    fetch('/__openfox_sessions')
      .then(function (res) {
        if (!res.ok) throw new Error('Failed to fetch sessions')
        return res.json()
      })
      .then(function (data) {
        window.__foxSessionsError = false
        window.__foxSessions = data.sessions || []
        // Auto-select most recent if none selected
        if (!window.__foxSelectedSessionId && window.__foxSessions.length > 0) {
          window.__foxSelectedSessionId = window.__foxSessions[0].id
          try {
            sessionStorage.setItem('__foxSelectedSessionId', window.__foxSelectedSessionId)
          } catch {}
        }
      })
      .catch(function () {
        window.__foxSessionsError = true
      })
  }

  function init() {
    if (window.__foxInspectInit) return
    window.__foxInspectInit = true
    document.head.appendChild(overlayStyle)
    document.body.appendChild(overlay)
    toggleBtn = document.getElementById('__fox-toggle')

    // Restore previously selected session
    try {
      var saved = sessionStorage.getItem('__foxSelectedSessionId')
      if (saved) window.__foxSelectedSessionId = saved
    } catch {}

    toggleBtn.addEventListener('click', function (e) {
      e.preventDefault()
      e.stopPropagation()
      if (window.__foxInspectMode) clearHighlights()
      setInspectMode(!window.__foxInspectMode)
    })

    overlay.style.display = window.__foxInspectEnabled ? '' : 'none'

    fetchSessions()
    setInterval(fetchSessions, 30000)
  }

  if (document.body) {
    init()
  } else {
    document.addEventListener('DOMContentLoaded', init)
  }
})()
