const article = document.querySelector('.prose');
const outline = document.querySelector('.page-outline');
if (article && outline) {
  for (const heading of article.querySelectorAll('h2[id]')) {
    const link = document.createElement('a');
    link.href = `#${heading.id}`;
    link.textContent = heading.textContent;
    outline.append(link);
  }
  outline.hidden = !outline.querySelector('a');
}

for (const table of document.querySelectorAll('.prose table')) {
  const wrapper = document.createElement('div');
  wrapper.className = 'table-scroll';
  wrapper.tabIndex = 0;
  wrapper.setAttribute('role', 'region');
  wrapper.setAttribute('aria-label', 'Scrollable table');
  table.before(wrapper);
  wrapper.append(table);
}

if (navigator.clipboard) {
  for (const pre of document.querySelectorAll('pre')) {
    const code = pre.querySelector('code');
    if (!code || code.closest('.language-mermaid')) continue;
    const button = document.createElement('button');
    button.className = 'copy-code';
    button.type = 'button';
    button.textContent = 'Copy';
    button.setAttribute('aria-label', 'Copy code to clipboard');
    button.addEventListener('click', async () => {
      try {
        await navigator.clipboard.writeText(code.textContent);
        button.textContent = 'Copied';
      } catch {
        const range = document.createRange();
        range.selectNodeContents(code);
        const selection = window.getSelection();
        selection.removeAllRanges();
        selection.addRange(range);
        button.textContent = 'Selected';
      }
      setTimeout(() => { button.textContent = 'Copy'; }, 2000);
    });
    pre.append(button);
  }
}

const diagrams = document.querySelectorAll('code.language-mermaid, .language-mermaid code');
if (diagrams.length) {
  try {
    const { default: mermaid } = await import('https://cdn.jsdelivr.net/npm/mermaid@12.1.0/dist/mermaid.esm.min.mjs');
    mermaid.initialize({
      startOnLoad: false,
      securityLevel: 'strict',
      look: 'classic',
      theme: 'base',
      themeVariables: {
        darkMode: true,
        background: '#101113',
        primaryColor: '#202328',
        primaryTextColor: '#f5f5f7',
        primaryBorderColor: '#59616a',
        lineColor: '#a6efc3',
        secondaryColor: '#181a1d',
        tertiaryColor: '#181a1d',
        edgeLabelBackground: '#181a1d',
        fontFamily: '-apple-system, BlinkMacSystemFont, sans-serif',
      },
    });
    for (const [index, code] of [...diagrams].entries()) {
      const { svg } = await mermaid.render(`diagram-${index}`, code.textContent);
      const figure = document.createElement('figure');
      figure.className = 'diagram';
      figure.tabIndex = 0;
      figure.setAttribute('role', 'region');
      figure.setAttribute('aria-label', 'Scrollable diagram');
      figure.innerHTML = svg;
      (code.closest('.highlighter-rouge') || code.closest('pre')).replaceWith(figure);
    }
  } catch (error) {
    console.warn('Diagram rendering unavailable; showing diagram source.', error);
  }
}
