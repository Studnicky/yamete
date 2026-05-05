/**
 * Click-to-expand + pan + zoom for every mermaid diagram on the page.
 * Uses MutationObserver so the enhancer catches SVGs whenever the
 * mermaid plugin hydrates them, regardless of route timing.
 */
import {
  onBeforeUnmount, onMounted
} from 'vue';

type Vec = { 'x': number;
  'y': number };

function buildModal(svg: SVGElement): () => void {
  const overlay = document.createElement('div');

  overlay.className = 'yamete-mermaid-modal';
  const toolbar = document.createElement('div');

  toolbar.className = 'yamete-mermaid-modal-toolbar';
  const zoomIn = document.createElement('button');

  zoomIn.textContent = '+ zoom';
  const zoomOut = document.createElement('button');

  zoomOut.textContent = '- zoom';
  const reset = document.createElement('button');

  reset.textContent = 'reset';
  const close = document.createElement('button');

  close.textContent = 'close (esc)';
  toolbar.append(zoomIn, zoomOut, reset, close);

  const stage = document.createElement('div');

  stage.className = 'yamete-mermaid-modal-stage';
  const cloned = svg.cloneNode(true) as SVGElement;

  cloned.removeAttribute('width');
  cloned.removeAttribute('height');
  cloned.setAttribute('preserveAspectRatio', 'xMidYMid meet')
  ;(cloned as unknown as HTMLElement).style.width = ''
  ;(cloned as unknown as HTMLElement).style.height = '';
  stage.appendChild(cloned);

  const hint = document.createElement('div');

  hint.className = 'yamete-mermaid-modal-hint';
  hint.textContent = 'drag to pan / wheel to zoom / esc to close';

  overlay.append(toolbar, stage, hint);
  document.body.appendChild(overlay);
  document.body.style.overflow = 'hidden';

  let scale = 1;
  const offset: Vec = {
    'x': 0,
    'y': 0
  };

  function fit() {
    const stageRect = stage.getBoundingClientRect();
    let bbox = {
      'height': 0,
      'width': 0
    };

    try {
      bbox = (cloned as SVGGraphicsElement).getBBox();
    } catch {}
    const sw = bbox.width || svg.getBoundingClientRect().width || 1024;
    const sh = bbox.height || svg.getBoundingClientRect().height || 768;
    const margin = 0.92;

    scale = Math.min((stageRect.width * margin) / sw, (stageRect.height * margin) / sh);
    offset.x = -(sw * scale) / 2;
    offset.y = -(sh * scale) / 2;
    apply();
  }

  function apply() {
    (cloned as unknown as HTMLElement).style.transform
      = `translate(${offset.x}px, ${offset.y}px) scale(${scale})`;
  }
  requestAnimationFrame(fit);

  function onWheel(e: WheelEvent) {
    e.preventDefault();
    const stageRect = stage.getBoundingClientRect();
    const cx = e.clientX - stageRect.left - stageRect.width / 2;
    const cy = e.clientY - stageRect.top - stageRect.height / 2;
    const factor = Math.exp(-e.deltaY * 0.0015);
    const next = Math.min(8, Math.max(0.1, scale * factor));

    offset.x = cx - (cx - offset.x) * (next / scale);
    offset.y = cy - (cy - offset.y) * (next / scale);
    scale = next;
    apply();
  }
  stage.addEventListener('wheel', onWheel, { 'passive': false });

  let dragging = false;
  let last: Vec = {
    'x': 0,
    'y': 0
  };

  stage.addEventListener('pointerdown', (e) => {
    dragging = true;
    last = {
      'x': e.clientX,
      'y': e.clientY
    };
    overlay.classList.add('dragging')
    ;(e.target as Element).setPointerCapture?.(e.pointerId);
  });
  stage.addEventListener('pointermove', (e) => {
    if (!dragging) {
      return;
    }
    offset.x += e.clientX - last.x;
    offset.y += e.clientY - last.y;
    last = {
      'x': e.clientX,
      'y': e.clientY
    };
    apply();
  });

  function endDrag() {
    dragging = false; overlay.classList.remove('dragging');
  }
  stage.addEventListener('pointerup', endDrag);
  stage.addEventListener('pointercancel', endDrag);

  function bumpZoom(factor: number) {
    scale = Math.min(8, Math.max(0.1, scale * factor));
    apply();
  }
  zoomIn.onclick = (e) => {
    e.stopPropagation(); bumpZoom(1.25);
  };
  zoomOut.onclick = (e) => {
    e.stopPropagation(); bumpZoom(0.8);
  };
  reset.onclick = (e) => {
    e.stopPropagation(); fit();
  };

  function destroy() {
    document.body.style.overflow = '';
    document.removeEventListener('keydown', onKey);
    overlay.remove();
  }

  function onKey(e: KeyboardEvent) {
    if (e.key === 'Escape') {
      destroy();
    }
  }
  document.addEventListener('keydown', onKey);
  close.onclick = (e) => {
    e.stopPropagation(); destroy();
  };
  overlay.addEventListener('click', (e) => {
    if (e.target === overlay || e.target === hint) {
      destroy();
    }
  });

  return destroy;
}

function enhanceFrame(frame: Element) {
  if ((frame as HTMLElement).dataset.yameteEnhanced === '1') {
    return;
  }
  const svg = frame.querySelector('svg');

  if (!svg) {
    return
    ;
  }(frame as HTMLElement).dataset.yameteEnhanced = '1';
  frame.classList.add('yamete-mermaid-frame');
  const btn = document.createElement('button');

  btn.className = 'yamete-mermaid-expand';
  btn.type = 'button';
  btn.textContent = 'expand';
  btn.title = 'Open in fullscreen pan/zoom view';
  btn.addEventListener('click', (e) => {
    e.stopPropagation();
    buildModal(svg as SVGElement);
  });
  frame.addEventListener('click', () => {
    const result = buildModal(svg as SVGElement);

    return result;
  });
  frame.appendChild(btn);
}

function enhanceAll() {
  const frames = document.querySelectorAll('.vp-doc div.mermaid, .vp-doc div[class*="mermaid"], .vp-doc .yamete-mermaid');

  frames.forEach(enhanceFrame);
}

export function useMermaidEnhancer() {
  let observer: MutationObserver | undefined;
  let interval: ReturnType<typeof setInterval> | undefined;

  onMounted(() => {
    enhanceAll();
    // Observe future mermaid SVG insertions (route changes, hydration)
    observer = new MutationObserver(() => {
      const result = enhanceAll();

      return result;
    });
    observer.observe(document.body, {
      'childList': true,
      'subtree': true
    });
    // Belt-and-suspenders: poll for the first 5 seconds in case the
    // observer misses the SVG insertion that the mermaid plugin does
    // synchronously inside a flush callback.
    let ticks = 0;

    interval = setInterval(() => {
      enhanceAll();
      if (++ticks > 20) {
        clearInterval(interval); interval = undefined;
      }
    }, 250);
  });
  onBeforeUnmount(() => {
    observer?.disconnect();
    if (interval) {
      clearInterval(interval);
    }
  });
}
