# FIX · t.fix（ledger.garble-truthsource-r5 t.fix r2）

工作树：`.worktrees/wt-fix`（`feat/garble-fix-r2`）。基线 `origin/main` = `a7b2a6c`（#72）。开工已 `git fetch`。

**派单 vs 简报：** 派单写不 commit / 不 send。简报：真相源未成立要按合法出口①**直投 leader**；收工仍要产物进 PR。本格 **直投 + 只交产物 PR，不改 `src/`**。

---

## 自查：100% 判别规则？

授权文件 `.team/nodes/garble/ROOTCAUSE.md` **自己写明未达 100%，第②步跳过，没有文件:行根因清单。**

| 矩阵 | 假阳 | 假阴 | 是否可当真相源 |
|---|---:|---:|---|
| A `garbled ⇔ mlw>term_cols`（N=550，79/471） | 0 | 0 | **否**（标注器 tautology，ROOTCAUSE §① 拒用） |
| B 非标注器字段 | 0 或有 | 79 或有 | **否**（最好是全假阴；没有任何 0/0 合法组合） |

ROOTCAUSE 原文：「**第一步未达 100%。不做第②步根因（文件:行）与事前预测。**」「**下一格不该是 t.fix。**」

后续格没有推翻这一点：

- ROOTCAUSE-2：合法字段仍无 0/0（75 错 / 475 正常）。
- REPRO / REPRO-2：受控台造不出现场那种 mlw=115。
- PANEWIDTH（#73，本树 main 尚未包含）：红帧 `tmux_pane_w` **就是 114**，reshape-没生效的推论被推翻，**仍不是**一条可反推到某文件:行的 100% 规则。

简报授权「只许修第③节反推出来的根因」。ROOTCAUSE **第③节是性能裁决**（50ms 不可达），不是根因清单，没有文件:行。

---

## 停手

⛔ **未改 `src/`、`docs/UI-SPEC.md`、产品测试。** 没有可执行的反推结果。继续改就是「猜一个改一个」（#54–#60 已全部回退）。

已直投 leader：真相源未成立，不该改代码。

未跑巡检修后数据（无修）。无 `sweep-after.jsonl`（无代码可验）。`npm test` 未因本格改动而跑——棘轮不降，也无新增。

---

## 判据对账

| # | 结果 |
|---|---|
| a | 本文件说明为何零条可修 |
| b | `sweep-after.jsonl` **未采**（未改代码） |
| c | 未改测试；不宣称新绿 |

verdict: unjudgeable
