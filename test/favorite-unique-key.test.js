import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  getAgentFavKey,
  isAgentFav,
  toggleAgentFav,
} from '../src/lib/favorites.js';

test('getAgentFavKey produces unique key bound to session uid/ref', () => {
  const spaceKey = 'local::/home/user/project';
  const session1 = { uid: 'local::%1', ref: '%1', title: 'pi' };
  const session2 = { uid: 'local::%2', ref: '%2', title: 'pi' };

  const key1 = getAgentFavKey(spaceKey, session1);
  const key2 = getAgentFavKey(spaceKey, session2);

  assert.equal(key1, 'local::/home/user/project::local::%1');
  assert.equal(key2, 'local::/home/user/project::local::%2');
  assert.notEqual(key1, key2, 'Two sessions with same name must produce distinct keys');
});

test('two sessions with identical names are favorited completely independently without collision', () => {
  const spaceKey = 'local::/home/user/project';
  const sessionA = { uid: 'local::pane-1', ref: 'pane-1', key: 'local::pane-1', title: 'pi' };
  const sessionB = { uid: 'local::pane-2', ref: 'pane-2', key: 'local::pane-2', title: 'pi' };

  let favs = [];

  // 初态：两者均未收藏
  assert.equal(isAgentFav(spaceKey, sessionA, new Set(favs)), false);
  assert.equal(isAgentFav(spaceKey, sessionB, new Set(favs)), false);

  // 1. 收藏 Session A
  favs = toggleAgentFav(favs, spaceKey, sessionA);

  // 核心断言：Session A 被收藏，但同名的 Session B 绝不带收藏状态！
  assert.equal(isAgentFav(spaceKey, sessionA, new Set(favs)), true, 'Session A must be favorited');
  assert.equal(isAgentFav(spaceKey, sessionB, new Set(favs)), false, 'Session B must NOT be favorited');

  // 2. 接着收藏 Session B
  favs = toggleAgentFav(favs, spaceKey, sessionB);

  // 两者均各自独立处于收藏态
  assert.equal(isAgentFav(spaceKey, sessionA, new Set(favs)), true);
  assert.equal(isAgentFav(spaceKey, sessionB, new Set(favs)), true);

  // 3. 取消收藏 Session A
  favs = toggleAgentFav(favs, spaceKey, sessionA);

  // 核心断言：Session A 成功取消，Session B 依然稳定保持收藏
  assert.equal(isAgentFav(spaceKey, sessionA, new Set(favs)), false, 'Session A must be unfavorited');
  assert.equal(isAgentFav(spaceKey, sessionB, new Set(favs)), true, 'Session B must remain favorited');
});

test('legacy favorite keys smoothly degrade and safely clean up on toggle', () => {
  const spaceKey = 'local::/home/user/project';
  const session = { uid: 'local::pane-1', ref: 'pane-1', key: 'local::pane-1', title: 'legacy-agent' };

  // 模拟旧版本 localStorage 中仅存有基于 title 的老键
  const legacyKey = `${spaceKey}::legacy-agent`;
  let favs = [legacyKey];

  // 1. 平滑兼容历史数据：未升级前依然正确识别为收藏态，绝不白屏崩溃
  assert.equal(isAgentFav(spaceKey, session, new Set(favs)), true);

  // 2. 当用户点击取消收藏时，清理老键，绝不残留
  favs = toggleAgentFav(favs, spaceKey, session);
  assert.equal(isAgentFav(spaceKey, session, new Set(favs)), false);
  assert.equal(favs.includes(legacyKey), false);

  // 3. 再次点击收藏时，写入新版唯一 key
  favs = toggleAgentFav(favs, spaceKey, session);
  assert.equal(isAgentFav(spaceKey, session, new Set(favs)), true);
  const expectedPrimaryKey = `${spaceKey}::local::pane-1`;
  assert.deepEqual(favs, [expectedPrimaryKey]);
});

test('isAgentFav handles empty, null, and invalid inputs gracefully without throwing', () => {
  const spaceKey = 'local::/home/user/project';
  assert.equal(isAgentFav(spaceKey, null, new Set()), false);
  assert.equal(isAgentFav(spaceKey, undefined, new Set()), false);
  assert.equal(isAgentFav(spaceKey, {}, new Set()), false);
  assert.equal(isAgentFav(spaceKey, { title: 'test' }, null), false);
});
