// Play and pause, speed, scrubber, keyboard.
export function createControls({ count, onPlayToggle, onSpeed, onSeek, onStep }) {
  const play = document.getElementById('play');
  const scrub = document.getElementById('scrubber');
  const speedButtons = [...document.querySelectorAll('.speed button')];
  scrub.max = count - 1;

  play.addEventListener('click', onPlayToggle);
  scrub.addEventListener('input', () => onSeek(+scrub.value));
  for (const b of speedButtons) {
    b.addEventListener('click', () => {
      for (const o of speedButtons) o.setAttribute('aria-pressed', String(o === b));
      onSpeed(+b.dataset.ms);
    });
  }

  document.addEventListener('keydown', (e) => {
    const t = e.target;
    if (t === scrub || e.metaKey || e.ctrlKey || e.altKey) return;
    if (e.key === 'ArrowRight' || e.key === 'ArrowLeft') {
      e.preventDefault();
      onStep(e.key === 'ArrowRight' ? 1 : -1);
    } else if (e.key === ' ' && !['BUTTON', 'SUMMARY', 'A'].includes(t.tagName)) {
      e.preventDefault();
      onPlayToggle();
    }
  });

  return {
    setDay(i, label) {
      scrub.value = i;
      scrub.setAttribute('aria-valuetext', label);
    },
    setState(state) {
      play.textContent = state === 'playing' ? 'Pause' : state === 'ended' ? 'Replay' : 'Play';
    },
  };
}
