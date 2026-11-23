// DSH 0.2.2-rc.5 stores the inherited prefix inline. Only the child session's
// own catalog events establish child identities (see dsh-subagent).
export async function resolveSessionTree(store, ids, snapshot) {
  const selected = new Set(ids);
  const rows = new Map();
  const warnings = new Set();
  for (const id of selected) {
    const row = await snapshot(store, id);
    rows.set(id, { ...row, selected: true, owners: [] });
  }

  const childrenByParent = new Map();
  try {
    for (const { header } of await store.list()) {
      if (header.origin !== 'subagent' || !header.parentSession) continue;
      const children = childrenByParent.get(header.parentSession) ?? [];
      children.push(header.id);
      childrenByParent.set(header.parentSession, children);
    }
    for (const children of childrenByParent.values()) children.sort();
  } catch (error) {
    warnings.add(`无法扫描 DSH 子会话头，将按现存目录事件查找依赖：${error.message}`);
  }

  const failed = new Map();
  async function readDependency(id, ownerId, isChild) {
    const label = isChild ? '子会话' : '父会话';
    if (!rows.has(id) && !failed.has(id)) {
      try {
        const row = await snapshot(store, id);
        rows.set(id, { ...row, selected: false, owners: [] });
      } catch (error) {
        failed.set(id, error.message);
      }
    }
    if (failed.has(id)) {
      warnings.add(`DSH 会话 ${ownerId} 的${label} ${id} 无法读取，已保留现存历史：${failed.get(id)}`);
      return false;
    }
    const { header } = rows.get(id);
    if (isChild && (header.origin !== 'subagent' || header.parentSession !== ownerId)) {
      warnings.add(`DSH 会话 ${ownerId} 的子会话 ${id} 与目录记录的父级不符，已保留现存历史`);
      return false;
    }
    return true;
  }

  const edges = new Map();
  async function neighbors(id) {
    if (edges.has(id)) return edges.get(id);
    const { header, events, inherited } = rows.get(id);
    const candidates = new Set(childrenByParent.get(id));
    for (const event of events) {
      if (event.type !== 'subagent/catalog' || event.seq < inherited) continue;
      if (event.data.mode !== 'external' && event.data.childId) candidates.add(event.data.childId);
    }
    const reachable = [];
    if (header.origin === 'subagent' && header.parentSession &&
        await readDependency(header.parentSession, id, false)) {
      reachable.push(header.parentSession);
    }
    for (const childId of candidates) {
      if (await readDependency(childId, id, true)) reachable.push(childId);
    }
    edges.set(id, reachable);
    return reachable;
  }

  for (const owner of selected) {
    const pending = [owner];
    const visited = new Set(pending);
    for (const id of pending) {
      rows.get(id).owners.push(owner);
      for (const neighbor of await neighbors(id)) {
        if (visited.has(neighbor)) continue;
        visited.add(neighbor);
        pending.push(neighbor);
      }
    }
  }
  return { rows: [...rows.values()].filter(row => row.owners.length), warnings: [...warnings] };
}
