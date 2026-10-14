const button = document.getElementById('copy-prompt');
const prompt = document.getElementById('setup-prompt');
const status = document.getElementById('copy-status');

button.hidden = false;
button.addEventListener('click', async () => {
  button.disabled = true;
  status.textContent = '';
  try {
    await navigator.clipboard.writeText(prompt.textContent.trim());
    button.textContent = 'Copy again';
    status.textContent = 'Copied! Paste into Codex.';
  } catch {
    // Clipboard access can be denied. Keep the exact text available to copy.
    prompt.focus();
    const range = document.createRange();
    range.selectNodeContents(prompt);
    const selection = window.getSelection();
    selection.removeAllRanges();
    selection.addRange(range);
    status.textContent = 'Copy the selected text, then paste it into Codex.';
  } finally {
    button.disabled = false;
  }
});
