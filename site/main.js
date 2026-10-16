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
