// Drag and drop (10.1): drop files, a folder or a screenshot onto the chat to give the Bot that context.
// Files and folders are copied into the Bot's Attachments (up to 10 per message, 20 MB each; a folder is read up to four levels deep,
// skipping hidden and build folders). A picture dragged in from a browser or another app, which has no file path, is saved as an image.
const IMAGE = /^image\/(png|jpeg|gif|webp)$/;

export function installDrop({ target, bridge, result, toast, currentBot, pendingCount, addFiles }) {
  if (!bridge.attachPaths || !target) return;
  const hasFiles = event => [...(event.dataTransfer?.types || [])].includes('Files');
  let depth = 0;
  const show = on => target.classList.toggle('dropping', on);
  target.addEventListener('dragenter', event => { if (!hasFiles(event)) return; event.preventDefault(); depth++; show(true); });
  target.addEventListener('dragover', event => { if (!hasFiles(event)) return; event.preventDefault(); event.dataTransfer.dropEffect = 'copy'; });
  target.addEventListener('dragleave', event => { if (!hasFiles(event)) return; depth = Math.max(0, depth - 1); if (!depth) show(false); });
  target.addEventListener('drop', async event => {
    if (!hasFiles(event)) return;
    event.preventDefault(); depth = 0; show(false);
    const bot = currentBot();
    if (!bot) return;
    if (bot.memberIDs) { toast('Drop files onto a single Bot’s chat. Groups cannot take attachments.'); return; }
    const paths = [], pictures = [];
    for (const file of [...event.dataTransfer.files]) {
      const path = bridge.pathForFile?.(file);
      if (path) paths.push(path); else if (IMAGE.test(file.type)) pictures.push(file); else toast(`“${file.name}” could not be attached.`);
    }
    try {
      if (paths.length) {
        const room = Math.max(0, 10 - pendingCount(bot));
        const done = await result(bridge.attachPaths(bot.id, paths, room));
        addFiles(bot, done.names);
        if (done.skipped) toast(`Attached ${done.names.length}. ${done.skipped} more ${done.skipped === 1 ? 'was' : 'were'} left out (up to 10 files per message, under 20 MB each).`);
      }
      for (const file of pictures) {
        if (file.size > 20_000_000) { toast('Images must be under 20 MB.'); continue; }
        const bytes = new Uint8Array(await file.arrayBuffer()); let binary = '';
        for (let i = 0; i < bytes.length; i += 0x8000) binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
        addFiles(bot, [await result(bridge.attachData(bot.id, file.type, btoa(binary)))]);
      }
    } catch (error) { toast(error.message); }
  });
}
