/** 内联 SVG 图标（UI-SPEC §9）。viewBox 24×24，size/strokeWidth 由调用方给。 */

function Ico({ size = 24, strokeWidth = 1.8, stroke = 'currentColor', fill = 'none', children, ...rest }) {
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill={fill}
      stroke={stroke}
      strokeWidth={strokeWidth}
      strokeLinecap="round"
      strokeLinejoin="round"
      style={{ flex: 'none' }}
      aria-hidden="true"
      {...rest}
    >
      {children}
    </svg>
  );
}

export function SidebarIcon(p) {
  return (
    <Ico strokeWidth={1.8} {...p}>
      <rect x="3" y="4" width="18" height="16" rx="3" />
      <line x1="9" y1="4" x2="9" y2="20" />
    </Ico>
  );
}

export function SearchIcon(p) {
  return (
    <Ico strokeWidth={1.8} {...p}>
      <circle cx="11" cy="11" r="7" />
      <line x1="21" y1="21" x2="16.5" y2="16.5" />
    </Ico>
  );
}

export function ChevronDown(p) {
  return (
    <Ico strokeWidth={2.2} {...p}>
      <polyline points="6 9 12 15 18 9" />
    </Ico>
  );
}

export function FolderIcon(p) {
  return (
    <Ico strokeWidth={1.8} {...p}>
      <path d="M4 20h16a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2h-7l-2-2H4a2 2 0 0 0-2 2v12a2 2 0 0 0 2 2Z" />
    </Ico>
  );
}

export function GridIcon(p) {
  return (
    <Ico strokeWidth={1.8} {...p}>
      <rect x="3" y="3" width="7" height="7" rx="1.5" />
      <rect x="14" y="3" width="7" height="7" rx="1.5" />
      <rect x="3" y="14" width="7" height="7" rx="1.5" />
      <rect x="14" y="14" width="7" height="7" rx="1.5" />
    </Ico>
  );
}

export function StarIcon({ fill = 'currentColor', ...p }) {
  return (
    <Ico fill={fill} stroke="none" strokeWidth={0} {...p}>
      <polygon points="12 2 15 8.5 22 9.3 17 14 18.2 21 12 17.5 5.8 21 7 14 2 9.3 9 8.5" />
    </Ico>
  );
}

export function StarOutline(p) {
  return (
    <Ico fill="none" strokeWidth={1.9} {...p}>
      <polygon points="12 2 15 8.5 22 9.3 17 14 18.2 21 12 17.5 5.8 21 7 14 2 9.3 9 8.5" />
    </Ico>
  );
}

export function LayersIcon(p) {
  return (
    <Ico strokeWidth={1.8} {...p}>
      <polygon points="12 2 2 7 12 12 22 7 12 2" />
      <polyline points="2 17 12 22 22 17" />
      <polyline points="2 12 12 17 22 12" />
    </Ico>
  );
}

export function MonitorIcon(p) {
  return (
    <Ico strokeWidth={1.8} {...p}>
      <rect x="2" y="4" width="20" height="13" rx="2" />
      <line x1="8" y1="21" x2="16" y2="21" />
      <line x1="12" y1="17" x2="12" y2="21" />
    </Ico>
  );
}

export function GearIcon(p) {
  return (
    <Ico strokeWidth={1.8} {...p}>
      <circle cx="12" cy="12" r="3" />
      <path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 1 1-4 0v-.09a1.65 1.65 0 0 0-1-1.51 1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 1 1 0-4h.09a1.65 1.65 0 0 0 1.51-1 1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06a1.65 1.65 0 0 0 1.82.33h0a1.65 1.65 0 0 0 1-1.51V3a2 2 0 1 1 4 0v.09a1.65 1.65 0 0 0 1 1.51h0a1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82v0a1.65 1.65 0 0 0 1.51 1H21a2 2 0 1 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1Z" />
    </Ico>
  );
}

export function CheckIcon(p) {
  return (
    <Ico strokeWidth={2.2} {...p}>
      <polyline points="20 6 9 17 4 12" />
    </Ico>
  );
}

export function XIcon(p) {
  return (
    <Ico strokeWidth={2} {...p}>
      <line x1="18" y1="6" x2="6" y2="18" />
      <line x1="6" y1="6" x2="18" y2="18" />
    </Ico>
  );
}

export function PlusIcon(p) {
  return (
    <Ico strokeWidth={1.8} {...p}>
      <line x1="12" y1="5" x2="12" y2="19" />
      <line x1="5" y1="12" x2="19" y2="12" />
    </Ico>
  );
}

export function SplitIcon(p) {
  return (
    <Ico strokeWidth={1.9} {...p}>
      <rect x="3" y="4" width="18" height="16" rx="2" />
      <line x1="12" y1="4" x2="12" y2="20" />
    </Ico>
  );
}

export function CloseLeftIcon(p) {
  return (
    <Ico strokeWidth={1.9} {...p}>
      <line x1="5" y1="4" x2="5" y2="20" />
      <path d="M19 12H9m0 0 4-4m-4 4 4 4" />
    </Ico>
  );
}

export function CloseRightIcon(p) {
  return (
    <Ico strokeWidth={1.9} {...p}>
      <line x1="19" y1="4" x2="19" y2="20" />
      <path d="M5 12h10m0 0-4-4m4 4-4 4" />
    </Ico>
  );
}

export function TerminalIcon(p) {
  return (
    <Ico strokeWidth={1.8} {...p}>
      <polyline points="4 17 10 11 4 5" />
      <line x1="12" y1="19" x2="20" y2="19" />
    </Ico>
  );
}

export function ArrowUpIcon(p) {
  return (
    <Ico strokeWidth={2} {...p}>
      <path d="M12 19V5m0 0-6 6m6-6 6 6" />
    </Ico>
  );
}
