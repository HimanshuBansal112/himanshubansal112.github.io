(function () {
  const themeToggle = document.getElementById('theme-toggle');
  const htmlEl = document.documentElement;

  const savedTheme = localStorage.getItem('hb_theme');
  if (savedTheme) {
    htmlEl.setAttribute('data-theme', savedTheme);
  } else if (window.matchMedia && window.matchMedia('(prefers-color-scheme: light)').matches) {
    htmlEl.setAttribute('data-theme', 'light');
  }

  function updateButtonText() {
    const currentTheme = htmlEl.getAttribute('data-theme') || 'dark';
    if (themeToggle) {
      themeToggle.textContent = currentTheme + ' mode';
      themeToggle.setAttribute('aria-pressed', currentTheme === 'light' ? 'true' : 'false');
    }
  }

  updateButtonText();

  if (themeToggle) {
    themeToggle.addEventListener('click', function () {
      const currentTheme = htmlEl.getAttribute('data-theme') || 'dark';
      const newTheme = currentTheme === 'dark' ? 'light' : 'dark';
      htmlEl.setAttribute('data-theme', newTheme);
      localStorage.setItem('hb_theme', newTheme);
      updateButtonText();
    });
  }
})();
