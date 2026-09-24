import { readFileSync } from 'node:fs';
import assert from 'node:assert/strict';

// Check the delivered PE, not just Rust source or linker configuration.
const path = process.argv[2] || 'src-tauri/target/release/corral-desktop.exe';
const pe = readFileSync(path);
assert.equal(pe.toString('ascii', 0, 2), 'MZ', 'expected a Windows executable');
const header = pe.readUInt32LE(0x3c);
assert.equal(pe.readUInt32LE(header), 0x00004550, 'expected a PE header');
const optional = header + 24;
assert.ok([0x10b, 0x20b].includes(pe.readUInt16LE(optional)), 'expected PE32 or PE32+');
const subsystem = pe.readUInt16LE(optional + 68);
assert.equal(subsystem, 2, `Windows release must use GUI subsystem, got ${subsystem}`);
console.log(`${path}: PE Windows GUI subsystem verified`);
