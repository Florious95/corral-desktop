import { useRef } from 'react';
import { PlusIcon } from '../../lib/icons.jsx';
import './terminal.css';

/** The plus button is the file half of the shared image upload chain. */
export default function InputBar({ disabled = false, onFile, hint = '' }) {
  const inputRef = useRef(null);
  const pick = () => inputRef.current?.click();
  const change = (event) => {
    const file = event.target.files?.[0];
    event.target.value = '';
    if (file) onFile?.(file);
  };
  return (
    <div className="terminal-inputbar">
      <button type="button" className="terminal-inputbar-plus" disabled={disabled} onClick={pick} title="选择图片">
        <PlusIcon size={16} strokeWidth={2} />
      </button>
      <input ref={inputRef} className="terminal-inputbar-file" type="file" accept="image/*" onChange={change} />
      <span className="terminal-inputbar-hint">{hint || 'Ctrl+V 粘贴图片 · Cmd+V 粘贴文字'}</span>
    </div>
  );
}
