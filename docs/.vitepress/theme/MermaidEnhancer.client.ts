/**
 * Adds click-to-expand + pan + zoom to every <div class="mermaid"> on the
 * page after VitePress renders it. Lives outside the SSR pass — runs only
 * in the browser, after the route changes.
 */
import { onContentUpdated, useRouter } from 'vitepress'

type Vec = { x: number; y: number }

function buildModal(svg: SVGElement): () => void {
  const overlay = document.createElement('div')
  overlay.className = 'yamete-mermaid-modal'

  const toolbar = document.createElement('div')
  toolbar.className = 'yamete-mermaid-modal-toolbar'

  const zoomIn = document.createElement('button')
  zoomIn.textContent = '+ zoom'
  const zoomOut = document.createElement('button')
  zoomOut.textContent = '- zoom'
  const reset = document.createElement('button')
  reset.textContent = 'reset'
  const close = document.createElement('button')
  close.textContent = 'close (esc)'
  toolbar.append(zoomIn, zoomOut, reset, close)

  const stage = document.createElement('div')
  stage.className = 'yamete-mermaid-modal-stage'

  const cloned = svg.cloneNode(true) as SVGElement
  // Strip width/height so it scales freely with our transforms
  cloned.removeAttribute('width')
  cloned.removeAttribute('height')
  cloned.style.width = ''
  cloned.style.height = ''
  stage.appendChild(cloned)

  const hint = document.createElement('div')
  hint.className = 'yamete-mermaid-modal-hint'
  hint.textContent = 'drag to pan · wheel to zoom · esc to close'

  overlay.append(toolbar, stage, hint)
  document.body.appendChild(overlay)
  document.body.style.overflow = 'hidden'

  // Initial fit-to-stage
  let scale = 1
  const offset: Vec = { x: 0, y: 0 }
  function fit() {
    const stageRect = stage.getBoundingClientRect()
    // SVG natural size
    const bbox = (cloned as SVGGraphicsElement).getBBox?.() ?? { width: 1024, height: 768 }
    const sw = bbox.width || cloned.clientWidth || 1024
    const sh = bbox.height || cloned.clientHeight || 768
    const margin = 0.92
    scale = Math.min((stageRect.width * margin) / sw, (stageRect.height * margin) / sh)
    offset.x = -(sw * scale) / 2
    offset.y = -(sh * scale) / 2
    apply()
  }
  function apply() {
    cloned.style.transform = `translate(${offset.x}px, ${offset.y}px) scale(${scale})`
  }
  // Defer to next frame so layout settles
  requestAnimationFrame(fit)

  // Wheel zoom (anchored to cursor)
  function onWheel(e: WheelEvent) {
    e.preventDefault()
    const stageRect = stage.getBoundingClientRect()
    const cx = e.clientX - stageRect.left - stageRect.width / 2
    const cy = e.clientY - stageRect.top - stageRect.height / 2
    const factor = Math.exp(-e.deltaY * 0.0015)
    const next = Math.min(8, Math.max(0.1, scale * factor))
    // Keep cursor anchored
    offset.x = cx - (cx - offset.x) * (next / scale)
    offset.y = cy - (cy - offset.y) * (next / scale)
    scale = next
    apply()
  }
  stage.addEventListener('wheel', onWheel, { passive: false })

  // Pan via pointer drag
  let dragging = false
  let last: Vec = { x: 0, y: 0 }
  function onPointerDown(e: PointerEvent) {
    dragging = true
    last = { x: e.clientX, y: e.clientY }
    overlay.classList.add('dragging')
    ;(e.target as Element).setPointerCapture?.(e.pointerId)
  }
  function onPointerMove(e: PointerEvent) {
    if (!dragging) return
    offset.x += e.clientX - last.x
    offset.y += e.clientY - last.y
    last = { x: e.clientX, y: e.clientY }
    apply()
  }
  function onPointerUp() {
    dragging = false
    overlay.classList.remove('dragging')
  }
  stage.addEventListener('pointerdown', onPointerDown)
  stage.addEventListener('pointermove', onPointerMove)
  stage.addEventListener('pointerup', onPointerUp)
  stage.addEventListener('pointercancel', onPointerUp)

  function bumpZoom(factor: number) {
    scale = Math.min(8, Math.max(0.1, scale * factor))
    apply()
  }
  zoomIn.onclick = (e) => { e.stopPropagation(); bumpZoom(1.25) }
  zoomOut.onclick = (e) => { e.stopPropagation(); bumpZoom(0.8) }
  reset.onclick = (e) => { e.stopPropagation(); fit() }

  function destroy() {
    document.body.style.overflow = ''
    document.removeEventListener('keydown', onKey)
    overlay.remove()
  }
  function onKey(e: KeyboardEvent) {
    if (e.key === 'Escape') destroy()
  }
  document.addEventListener('keydown', onKey)
  close.onclick = (e) => { e.stopPropagation(); destroy() }
  // Click outside the SVG closes (but not when clicking on stage controls or the SVG itself)
  overlay.addEventListener('click', (e) => {
    if (e.target === overlay || e.target === hint) destroy()
  })

  return destroy
}

function enhanceAll() {
  const frames = document.querySelectorAll('.vp-doc div.mermaid, .vp-doc div[class*="mermaid"]')
  frames.forEach((frame) => {
    if (frame.querySelector('.yamete-mermaid-expand')) return // already enhanced
    const svg = frame.querySelector('svg')
    if (!svg) return
    frame.classList.add('yamete-mermaid-frame')
    const btn = document.createElement('button')
    btn.className = 'yamete-mermaid-expand'
    btn.type = 'button'
    btn.textContent = '⤢ expand'
    btn.title = 'Open in fullscreen pan/zoom view'
    btn.addEventListener('click', (e) => {
      e.stopPropagation()
      buildModal(svg as SVGElement)
    })
    frame.addEventListener('click', () => buildModal(svg as SVGElement))
    frame.appendChild(btn)
  })
}

export function useMermaidEnhancer() {
  const router = useRouter()
  // Run once after each route render. Mermaid SVGs are produced by the
  // plugin's hydration; defer one frame so they're attached.
  onContentUpdated(() => {
    requestAnimationFrame(() => enhanceAll())
  })
  router.onAfterRouteChange = () => {
    requestAnimationFrame(() => enhanceAll())
  }
}
