// Langue : choix enregistré, sinon celle du navigateur (français ou anglais).
(function () {
  var stored = null;
  try { stored = localStorage.getItem('plume-lang'); } catch (e) {}
  var lang = stored || ((navigator.language || 'en').toLowerCase().indexOf('fr') === 0 ? 'fr' : 'en');

  function apply(l) {
    document.documentElement.lang = l;
    document.querySelectorAll('[data-' + l + ']').forEach(function (el) {
      el.textContent = el.getAttribute('data-' + l);
    });
    document.title = l === 'fr' ? 'Plume, la dictée vocale pour Mac' : 'Plume, voice dictation for Mac';
    var button = document.getElementById('lang');
    if (button) button.textContent = l === 'fr' ? 'EN' : 'FR';
  }

  document.addEventListener('DOMContentLoaded', function () {
    apply(lang);
    document.getElementById('lang').addEventListener('click', function () {
      lang = lang === 'fr' ? 'en' : 'fr';
      try { localStorage.setItem('plume-lang', lang); } catch (e) {}
      apply(lang);
    });
  });
})();

// Carrousel des captures : défile tout seul, s'arrête dès qu'on le fait défiler
// à la main (molette, trackpad, glisser, toucher, flèches) et repart 2 s après.
(function () {
  var SPEED = 38;          // px par seconde
  var RESUME_AFTER = 2000; // ms sans geste avant de repartir

  document.addEventListener('DOMContentLoaded', function () {
    var box = document.getElementById('marquee');
    if (!box) return;
    var reduced = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    var pos = 0, last = 0, pausedUntil = 0, lightboxOpen = false;

    function half() { return box.scrollWidth / 2; }
    // La piste contient deux fois les images : on recale d'une moitié pour boucler sans fin.
    function wrap() {
      var h = half();
      if (h <= 0) return;
      if (box.scrollLeft >= h) box.scrollLeft -= h;
      else if (box.scrollLeft <= 0) box.scrollLeft += h;
      pos = box.scrollLeft;
    }
    function pause() { pausedUntil = performance.now() + RESUME_AFTER; }

    function tick(now) {
      var dt = last ? Math.min(now - last, 64) : 0;
      last = now;
      if (!reduced && !lightboxOpen && now >= pausedUntil) {
        pos += SPEED * dt / 1000;
        if (pos >= half()) pos -= half();
        box.scrollLeft = pos;
      }
      requestAnimationFrame(tick);
    }

    box.addEventListener('wheel', pause, { passive: true });
    box.addEventListener('touchstart', pause, { passive: true });
    box.addEventListener('keydown', pause);
    box.addEventListener('scroll', function () {
      if (performance.now() < pausedUntil) { wrap(); }
    }, { passive: true });

    // Glisser à la souris (un vrai glisser ne compte pas comme un clic).
    var drag = null;
    box.addEventListener('pointerdown', function (e) {
      if (e.pointerType !== 'mouse' || e.button !== 0) return;
      drag = { x: e.clientX, left: box.scrollLeft, moved: false };
      pause();
    });
    window.addEventListener('pointermove', function (e) {
      if (!drag) return;
      var dx = e.clientX - drag.x;
      if (Math.abs(dx) > 4) { drag.moved = true; box.classList.add('dragging'); }
      box.scrollLeft = drag.left - dx;
      wrap();
      pause();
    });
    window.addEventListener('pointerup', function () {
      if (!drag) return;
      var moved = drag.moved;
      setTimeout(function () { drag = null; box.classList.remove('dragging'); }, moved ? 0 : 0);
      if (moved) box.dataset.justDragged = '1';
      pause();
    });

    // Clic sur une image : elle grandit depuis sa place ; clic n'importe où pour la remettre.
    box.addEventListener('click', function (e) {
      if (box.dataset.justDragged) { delete box.dataset.justDragged; return; }
      var img = e.target.closest('.shot img');
      if (img) open(img);
    });

    function open(img) {
      lightboxOpen = true;
      var from = img.getBoundingClientRect();
      var ratio = img.naturalWidth / img.naturalHeight || from.width / from.height;
      var vw = window.innerWidth, vh = window.innerHeight;
      var w = Math.min(vw * 0.92, vh * 0.86 * ratio, img.naturalWidth || Infinity);
      var h = w / ratio;
      var x = (vw - w) / 2, y = (vh - h) / 2;

      var overlay = document.createElement('div');
      overlay.className = 'lightbox';
      var big = img.cloneNode();
      big.removeAttribute('loading');
      big.style.left = x + 'px'; big.style.top = y + 'px';
      big.style.width = w + 'px'; big.style.height = h + 'px';
      overlay.appendChild(big);
      document.body.appendChild(overlay);
      img.style.visibility = 'hidden';

      var start = 'translate(' + (from.left - x) + 'px,' + (from.top - y) + 'px) scale(' + (from.width / w) + ')';
      var ease = 'cubic-bezier(0.2, 0.9, 0.25, 1)';
      var dur = reduced ? 1 : 420;
      big.animate([{ transform: start }, { transform: 'none' }], { duration: dur, easing: ease });
      overlay.animate([{ opacity: 0 }, { opacity: 1 }], { duration: reduced ? 150 : 300, easing: 'ease-out' });

      function close() {
        document.removeEventListener('keydown', onKey);
        overlay.removeEventListener('click', close);
        var to = img.getBoundingClientRect();
        var end = 'translate(' + (to.left - x) + 'px,' + (to.top - y) + 'px) scale(' + (to.width / w) + ')';
        big.animate([{ transform: 'none' }, { transform: end }], { duration: dur * 0.85, easing: ease, fill: 'forwards' });
        var fade = overlay.animate([{ opacity: 1 }, { opacity: 0 }], { duration: dur * 0.85, easing: 'ease-in', fill: 'forwards' });
        fade.onfinish = function () {
          img.style.visibility = '';
          overlay.remove();
          lightboxOpen = false;
          pause();
        };
      }
      function onKey(e) { if (e.key === 'Escape') close(); }
      overlay.addEventListener('click', close);
      document.addEventListener('keydown', onKey);
    }

    requestAnimationFrame(tick);
  });
})();
