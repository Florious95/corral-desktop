/**
 * 会话收藏状态与唯一 Key 管理模块
 * 根治同名会话（如多个 pi 或 bash）在同一或不同目录下的收藏串染缺陷。
 */

/**
 * 获取会话的全局唯一收藏 Key
 * 绑定空间标识与会话唯一标识 (uid/ref)，彻底杜绝同名碰撞
 *
 * @param {string} spaceKey
 * @param {Object} agentOrSession
 * @returns {string}
 */
export function getAgentFavKey(spaceKey, agentOrSession) {
  const uid = agentOrSession?.uid || agentOrSession?.key || agentOrSession?.ref || '';
  return `${spaceKey}::${uid}`;
}

/**
 * 判断会话是否处于收藏状态（优先唯一标识，平滑兼容历史 title 键）
 *
 * @param {string} spaceKey
 * @param {Object} agentOrSession
 * @param {Set<string>} favSet
 * @returns {boolean}
 */
export function isAgentFav(spaceKey, agentOrSession, favSet) {
  if (!favSet || favSet.size === 0 || !agentOrSession) return false;
  const uid = agentOrSession.uid || agentOrSession.key || agentOrSession.ref;
  const ref = agentOrSession.ref;
  const name = agentOrSession.name || agentOrSession.title;

  // 1. 优先使用唯一标识精准匹配（主通道：消灭同名碰撞）
  if (uid && favSet.has(`${spaceKey}::${uid}`)) return true;
  if (ref && favSet.has(`${spaceKey}::${ref}`)) return true;
  if (uid && favSet.has(uid)) return true;

  // 2. 平滑兼容历史基于 title/name 的旧版收藏键（平滑升级，防崩保活）
  if (name && favSet.has(`${spaceKey}::${name}`)) return true;

  return false;
}

/**
 * 切换收藏状态纯函数（保证只操作目标特定会话的唯一标识，并安全清理历史关联键）
 *
 * @param {string[]} prevFavs
 * @param {string} spaceKey
 * @param {Object} agentOrSession
 * @returns {string[]}
 */
export function toggleAgentFav(prevFavs, spaceKey, agentOrSession) {
  const favArray = Array.isArray(prevFavs) ? prevFavs : [];
  const primaryKey = getAgentFavKey(spaceKey, agentOrSession);
  const legacyKey = `${spaceKey}::${agentOrSession.title || agentOrSession.name || ''}`;
  const refKey = `${spaceKey}::${agentOrSession.ref || ''}`;
  const uid = agentOrSession.uid || agentOrSession.key;

  const currentFavSet = new Set(favArray);
  const currentlyFav = isAgentFav(spaceKey, agentOrSession, currentFavSet);

  if (currentlyFav) {
    // 取消收藏：从列表中剔除该会话的主键及所有可能关联的历史键
    return favArray.filter((k) => k !== primaryKey && k !== legacyKey && k !== refKey && k !== uid);
  } else {
    // 添加收藏：仅添加新的唯一标识主键，并剔除历史模糊键防止再次串染
    return [...favArray.filter((k) => k !== primaryKey && k !== legacyKey), primaryKey];
  }
}
