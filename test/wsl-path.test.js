import { test } from 'node:test';
import assert from 'node:assert/strict';
import { windowsToWsl, wslToWindows } from '../src/lib/wslPath.js';
import { formatClipboardFiles } from '../src/term/clipboard.js';

test('windowsToWsl converts drive letters and UNC paths to POSIX', () => {
  assert.equal(windowsToWsl('C:\\Users\\foo\\code'), '/mnt/c/Users/foo/code');
  assert.equal(windowsToWsl('D:\\Projects\\tmux桌面端\\src'), '/mnt/d/Projects/tmux桌面端/src');
  assert.equal(windowsToWsl('c:/users/foo/code'), '/mnt/c/users/foo/code');
  assert.equal(windowsToWsl('C:\\'), '/mnt/c');
  assert.equal(windowsToWsl('\\\\wsl.localhost\\Ubuntu\\home\\foo\\code'), '/home/foo/code');
  assert.equal(windowsToWsl('\\\\wsl$\\Ubuntu\\home\\foo\\code'), '/home/foo/code');

  // 原生 POSIX 绝对路径原样返回
  assert.equal(windowsToWsl('/home/foo/code'), '/home/foo/code');
  assert.equal(windowsToWsl('/mnt/c/Users/foo'), '/mnt/c/Users/foo');

  // 空值与边界防护
  assert.equal(windowsToWsl(''), '');
  assert.equal(windowsToWsl(null), '');
  assert.equal(windowsToWsl(undefined), '');
});

test('wslToWindows converts mount points and home directory to Windows paths', () => {
  assert.equal(wslToWindows('/mnt/c/Users/foo/code'), 'C:\\Users\\foo\\code');
  assert.equal(wslToWindows('/mnt/d/work/repo'), 'D:\\work\\repo');
  assert.equal(wslToWindows('/mnt/c'), 'C:\\');
  assert.equal(wslToWindows('/home/foo/code', 'Ubuntu'), '\\\\wsl.localhost\\Ubuntu\\home\\foo\\code');
  assert.equal(wslToWindows('/home/foo/code'), '\\\\wsl.localhost\\Ubuntu\\home\\foo\\code');

  // 空值与边界防护
  assert.equal(wslToWindows(''), '');
  assert.equal(wslToWindows(null), '');
  assert.equal(wslToWindows(undefined), '');
});

test('formatClipboardFiles seamlessly maps Windows drive paths to WSL POSIX paths', () => {
  // 单个无空格安全盘符路径
  assert.equal(formatClipboardFiles(['C:\\Users\\foo\\code.txt']), '/mnt/c/Users/foo/code.txt');

  // 多个 Windows 路径，包含空格自动转义
  assert.equal(
    formatClipboardFiles(['C:\\Users\\foo\\one.txt', 'D:\\My Documents\\two.txt']),
    "/mnt/c/Users/foo/one.txt '/mnt/d/My Documents/two.txt'"
  );

  // UNC 路径转换
  assert.equal(
    formatClipboardFiles(['\\\\wsl.localhost\\Ubuntu\\home\\foo\\main.rs']),
    '/home/foo/main.rs'
  );
  assert.equal(
    formatClipboardFiles(['\\\\wsl$\\Ubuntu\\home\\foo\\main.rs']),
    '/home/foo/main.rs'
  );
  assert.equal(
    formatClipboardFiles(['\\\\WSL.LOCALHOST\\Ubuntu\\home\\foo\\main.rs']),
    '/home/foo/main.rs'
  );

  // 非法字符防护拦截
  assert.throws(() => formatClipboardFiles(['C:\\Users\\foo\\bad\nname']), /无法安全粘贴/);
  assert.throws(() => formatClipboardFiles(['C:\\Users\\foo\\bad\0name']), /无法安全粘贴/);

  // 相对路径依然拒绝
  assert.throws(() => formatClipboardFiles(['relative\\file.txt']), /无法安全粘贴/);
});

test('windowsToWsl and formatClipboardFiles fail closed on non-WSL UNC paths', () => {
  // 1. windowsToWsl 必须对非 WSL UNC 路径返回空串
  assert.equal(windowsToWsl('\\\\evil\\share\\x'), '');
  assert.equal(windowsToWsl('\\\\192.168.1.100\\c$\\secret.txt'), '');
  assert.equal(windowsToWsl('\\\\attacker\\payload'), '');
  assert.equal(windowsToWsl('//evil/share/x'), '');
  assert.equal(windowsToWsl('relative/path.txt'), '');

  // 2. formatClipboardFiles 必须严格 fail-closed 拒绝非 WSL 网络共享路径
  assert.throws(() => formatClipboardFiles(['\\\\evil\\share\\x']), /无法安全粘贴/);
  assert.throws(() => formatClipboardFiles(['\\\\192.168.1.100\\c$\\secret.txt']), /无法安全粘贴/);
  assert.throws(() => formatClipboardFiles(['\\\\attacker\\payload']), /无法安全粘贴/);
  assert.throws(() => formatClipboardFiles(['//evil/share/x']), /无法安全粘贴/);
  assert.throws(() => formatClipboardFiles(['//localhost/share']), /无法安全粘贴/);
});
