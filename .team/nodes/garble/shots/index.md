# 逐会话截图（t.shots）

路线 **B**（`tmux capture-pane -e -p` 只读，喂进本地 xterm.js，无头 Chrome 截 PNG）。

选择理由：席位纪律 §1.6 禁止对真实会话 subscribe（退订也会 reshape）。B 全程不连 `:9900`、不发 subscribe/resize/send-keys。capture-pane 只读。xterm `convertEol: true` 只为把 capture 的裸 LF 画成与 tmux 行盒一致的画面，方便看框线/中英文对齐；这不是产品改动，也不是错乱判定。

- 扫描 socket 目录 `/tmp/tmux-501`：31 个（list-panes 失败 3）
- 列出的 pane 数 **79**
- 写成 PNG **79**
- 未取到 **3**
- 截图前后几何是否全部相同：是

| 文件名 | socket | pane | 工程目录 | 几何 | 截图前 | 截图后 | 备注 |
|---|---|---|---|---|---|---|---|
| — | appv-proof | — | — | — | — | — | 未取到：list-panes 失败（no server running on /tmp/tmux-501/appv-proof） |
| default__p0.png | default | %0 | /Volumes/nvme/Projects/通用问题对话-chat | 235x48 | 235x48 | 235x48 |  |
| default__p1.png | default | %1 | /Volumes/nvme/Projects/研究loopx | 235x50 | 235x50 | 235x50 |  |
| default__p2.png | default | %2 | /Users/alauda | 80x24 | 80x24 | 80x24 |  |
| default__p3.png | default | %3 | /Volumes/nvme/Projects/通用问题对话-chat | 80x24 | 80x24 | 80x24 |  |
| default__p4.png | default | %4 | /Volumes/nvme/Projects/研究deerflow | 235x50 | 235x50 | 235x50 |  |
| ta-0c657fffd082__p1.png | ta-0c657fffd082 | %1 | /private/var/folders/45/xpp3dfrd3dsgh482sxfl_2f80000gn/T/ta-hermetic-fts-red2-52382-4/workspace-fts-red2-5 | 80x24 | 80x24 | 80x24 |  |
| ta-105089ea391b__p0.png | ta-105089ea391b | %0 | /Volumes/nvme/Projects/通用问题对话-chat | 235x50 | 235x50 | 235x50 |  |
| ta-1e044accdb5e__p1.png | ta-1e044accdb5e | %1 | /private/var/folders/45/xpp3dfrd3dsgh482sxfl_2f80000gn/T/ta-hermetic-fts-red4-52382-2/workspace-fts-red4-3 | 80x24 | 80x24 | 80x24 |  |
| ta-2279e65e7c10__p5.png | ta-2279e65e7c10 | %5 | /private/var/folders/45/xpp3dfrd3dsgh482sxfl_2f80000gn/T/ta-rs-mcp-sim-97015-1787442328285100000-0 | 80x24 | 80x24 | 80x24 |  |
| ta-26d9380bb57c__p5.png | ta-26d9380bb57c | %5 | /private/var/folders/45/xpp3dfrd3dsgh482sxfl_2f80000gn/T/ta-rs-mcp-sim-85535-1787443613965697000-0 | 80x24 | 80x24 | 80x24 |  |
| ta-26fb88f58006__p0.png | ta-26fb88f58006 | %0 | /Volumes/nvme/Projects/本地部署 | 235x50 | 235x50 | 235x50 |  |
| ta-294849a082cf__p5.png | ta-294849a082cf | %5 | /private/var/folders/45/xpp3dfrd3dsgh482sxfl_2f80000gn/T/ta-rs-mcp-sim-37729-1787463545932445000-0 | 80x24 | 80x24 | 80x24 |  |
| ta-55d702008d4c__p1.png | ta-55d702008d4c | %1 | /private/var/folders/45/xpp3dfrd3dsgh482sxfl_2f80000gn/T/ta-hermetic-fts-red3-52382-6/workspace-fts-red3-7 | 80x24 | 80x24 | 80x24 |  |
| ta-5674137b752d__p0.png | ta-5674137b752d | %0 | /private/tmp/ta-p9-zSXs79 | 140x40 | 140x40 | 140x40 |  |
| ta-7633f2f9901c__p5.png | ta-7633f2f9901c | %5 | /private/var/folders/45/xpp3dfrd3dsgh482sxfl_2f80000gn/T/ta-rs-mcp-sim-92592-1787464405841071000-0 | 80x24 | 80x24 | 80x24 |  |
| — | ta-824b55142da8 | — | — | — | — | — | 未取到：list-panes 失败（no server running on /tmp/tmux-501/ta-824b55142da8） |
| ta-880900b92dbe__p5.png | ta-880900b92dbe | %5 | /private/var/folders/45/xpp3dfrd3dsgh482sxfl_2f80000gn/T/ta-rs-mcp-sim-58298-1787442816535751000-6 | 80x24 | 80x24 | 80x24 |  |
| ta-94d6068e0af7__p5.png | ta-94d6068e0af7 | %5 | /private/var/folders/45/xpp3dfrd3dsgh482sxfl_2f80000gn/T/ta-rs-mcp-sim-71484-1787463128161660000-0 | 80x24 | 80x24 | 80x24 |  |
| ta-a03565a3c6d0__p5.png | ta-a03565a3c6d0 | %5 | /private/var/folders/45/xpp3dfrd3dsgh482sxfl_2f80000gn/T/ta-rs-mcp-sim-46743-1787463319945467000-0 | 80x24 | 80x24 | 80x24 |  |
| ta-a0afa5f9c7f6__p0.png | ta-a0afa5f9c7f6 | %0 | /Volumes/nvme/Projects/讨论team-agent | 235x50 | 235x50 | 235x50 |  |
| ta-a0afa5f9c7f6__p10.png | ta-a0afa5f9c7f6 | %10 | /Volumes/nvme/Projects/无等编排 | 235x50 | 235x50 | 235x50 |  |
| ta-a0afa5f9c7f6__p4.png | ta-a0afa5f9c7f6 | %4 | /Volumes/nvme/Projects/无等编排 | 235x50 | 235x50 | 235x50 |  |
| ta-a0afa5f9c7f6__p5.png | ta-a0afa5f9c7f6 | %5 | /Volumes/nvme/Projects/无等编排 | 235x50 | 235x50 | 235x50 |  |
| ta-a0afa5f9c7f6__p6.png | ta-a0afa5f9c7f6 | %6 | /Volumes/nvme/Projects/无等编排 | 235x50 | 235x50 | 235x50 |  |
| ta-a0afa5f9c7f6__p7.png | ta-a0afa5f9c7f6 | %7 | /Volumes/nvme/Projects/无等编排 | 235x50 | 235x50 | 235x50 |  |
| ta-a0afa5f9c7f6__p8.png | ta-a0afa5f9c7f6 | %8 | /Volumes/nvme/Projects/无等编排 | 235x50 | 235x50 | 235x50 |  |
| ta-a0afa5f9c7f6__p9.png | ta-a0afa5f9c7f6 | %9 | /Volumes/nvme/Projects/讨论team-agent | 235x50 | 235x50 | 235x50 |  |
| ta-a0afa5f9c7f6__p11.png | ta-a0afa5f9c7f6 | %11 | /Volumes/nvme/Projects/无等编排-审查 | 80x24 | 80x24 | 80x24 |  |
| ta-a0afa5f9c7f6__p2.png | ta-a0afa5f9c7f6 | %2 | /Volumes/nvme/Projects/讨论team-agent | 235x50 | 235x50 | 235x50 |  |
| ta-a1bf231e9b2e__p5.png | ta-a1bf231e9b2e | %5 | /private/var/folders/45/xpp3dfrd3dsgh482sxfl_2f80000gn/T/ta-rs-mcp-sim-3980-1787464432284597000-0 | 80x24 | 80x24 | 80x24 |  |
| ta-a9fd5b7defbd__p0.png | ta-a9fd5b7defbd | %0 | /Users/alauda/Documents/code/agent前沿探索/多agent协作 | 142x42 | 142x42 | 142x42 |  |
| ta-a9fd5b7defbd__p1.png | ta-a9fd5b7defbd | %1 | /Users/alauda/Documents/code/agent前沿探索/多agent协作 | 235x50 | 235x50 | 235x50 |  |
| ta-a9fd5b7defbd__p2.png | ta-a9fd5b7defbd | %2 | /Users/alauda/Documents/code/agent前沿探索/多agent协作 | 235x50 | 235x50 | 235x50 |  |
| ta-a9fd5b7defbd__p72.png | ta-a9fd5b7defbd | %72 | /Users/alauda/Documents/code/agent前沿探索/多agent协作 | 235x50 | 235x50 | 235x50 |  |
| ta-a9fd5b7defbd__p73.png | ta-a9fd5b7defbd | %73 | /Users/alauda/Documents/code/agent前沿探索/多agent协作 | 235x50 | 235x50 | 235x50 |  |
| ta-a9fd5b7defbd__p74.png | ta-a9fd5b7defbd | %74 | /Users/alauda/Documents/code/agent前沿探索/多agent协作 | 235x50 | 235x50 | 235x50 |  |
| ta-a9fd5b7defbd__p75.png | ta-a9fd5b7defbd | %75 | /Users/alauda/Documents/code/agent前沿探索/多agent协作 | 137x42 | 137x42 | 137x42 |  |
| ta-a9fd5b7defbd__p76.png | ta-a9fd5b7defbd | %76 | /Users/alauda/Documents/code/agent前沿探索/多agent协作 | 235x50 | 235x50 | 235x50 |  |
| ta-a9fd5b7defbd__p77.png | ta-a9fd5b7defbd | %77 | /Users/alauda/Documents/code/agent前沿探索/多agent协作 | 235x50 | 235x50 | 235x50 |  |
| ta-a9fd5b7defbd__p92.png | ta-a9fd5b7defbd | %92 | /Users/alauda/Documents/code/agent前沿探索/多agent协作 | 235x50 | 235x50 | 235x50 |  |
| ta-a9fd5b7defbd__p80.png | ta-a9fd5b7defbd | %80 | /Users/alauda/Documents/code/agent前沿探索/多agent协作 | 235x50 | 235x50 | 235x50 |  |
| ta-a9fd5b7defbd__p90.png | ta-a9fd5b7defbd | %90 | /Users/alauda/Documents/code/agent前沿探索/多agent协作 | 235x50 | 235x50 | 235x50 |  |
| ta-a9fd5b7defbd__p85.png | ta-a9fd5b7defbd | %85 | /Users/alauda/Documents/code/agent前沿探索/多agent协作 | 235x50 | 235x50 | 235x50 |  |
| ta-a9fd5b7defbd__p93.png | ta-a9fd5b7defbd | %93 | /Users/alauda/Documents/code/agent前沿探索/多agent协作 | 235x50 | 235x50 | 235x50 |  |
| ta-a9fd5b7defbd__p94.png | ta-a9fd5b7defbd | %94 | /Users/alauda/Documents/code/agent前沿探索/多agent协作 | 235x50 | 235x50 | 235x50 |  |
| ta-a9fd5b7defbd__p95.png | ta-a9fd5b7defbd | %95 | /Users/alauda/Documents/code/agent前沿探索/多agent协作 | 235x50 | 235x50 | 235x50 |  |
| ta-a9fd5b7defbd__p96.png | ta-a9fd5b7defbd | %96 | /Users/alauda/Documents/code/agent前沿探索/多agent协作 | 235x50 | 235x50 | 235x50 |  |
| ta-a9fd5b7defbd__p97.png | ta-a9fd5b7defbd | %97 | /Users/alauda/Documents/code/agent前沿探索/多agent协作 | 235x50 | 235x50 | 235x50 |  |
| ta-a9fd5b7defbd__p98.png | ta-a9fd5b7defbd | %98 | /Users/alauda/Documents/code/agent前沿探索/多agent协作 | 235x50 | 235x50 | 235x50 |  |
| ta-a9fd5b7defbd__p99.png | ta-a9fd5b7defbd | %99 | /Users/alauda/Documents/code/agent前沿探索/多agent协作 | 235x50 | 235x50 | 235x50 |  |
| ta-a9fd5b7defbd__p100.png | ta-a9fd5b7defbd | %100 | /Users/alauda/Documents/code/agent前沿探索/多agent协作 | 235x50 | 235x50 | 235x50 |  |
| ta-a9fd5b7defbd__p101.png | ta-a9fd5b7defbd | %101 | /Users/alauda/Documents/code/agent前沿探索/多agent协作 | 235x50 | 235x50 | 235x50 |  |
| ta-a9fd5b7defbd__p102.png | ta-a9fd5b7defbd | %102 | /Users/alauda/Documents/code/agent前沿探索/多agent协作 | 235x50 | 235x50 | 235x50 |  |
| ta-a9fd5b7defbd__p103.png | ta-a9fd5b7defbd | %103 | /Users/alauda/Documents/code/agent前沿探索/多agent协作 | 235x50 | 235x50 | 235x50 |  |
| ta-a9fd5b7defbd__p104.png | ta-a9fd5b7defbd | %104 | /Users/alauda/Documents/code/agent前沿探索/多agent协作 | 235x50 | 235x50 | 235x50 |  |
| ta-a9fd5b7defbd__p105.png | ta-a9fd5b7defbd | %105 | /Users/alauda/Documents/code/agent前沿探索/多agent协作 | 235x50 | 235x50 | 235x50 |  |
| ta-a9fd5b7defbd__p106.png | ta-a9fd5b7defbd | %106 | /Users/alauda/Documents/code/agent前沿探索/多agent协作 | 235x50 | 235x50 | 235x50 |  |
| — | ta-ac195e227795 | — | — | — | — | — | 未取到：list-panes 失败（no server running on /tmp/tmux-501/ta-ac195e227795） |
| ta-b7cc1c640ccf__p0.png | ta-b7cc1c640ccf | %0 | /Volumes/nvme/Projects/远程Agent安卓 | 235x50 | 235x50 | 235x50 |  |
| ta-b7cc1c640ccf__p1.png | ta-b7cc1c640ccf | %1 | /Volumes/nvme/Projects/远程Agent安卓 | 80x24 | 80x24 | 80x24 |  |
| ta-b7cc1c640ccf__p88.png | ta-b7cc1c640ccf | %88 | /Volumes/nvme/Projects/远程Agent安卓 | 235x50 | 235x50 | 235x50 |  |
| ta-b7cc1c640ccf__p3.png | ta-b7cc1c640ccf | %3 | /Volumes/nvme/Projects/远程Agent安卓 | 235x50 | 235x50 | 235x50 |  |
| ta-b7cc1c640ccf__p89.png | ta-b7cc1c640ccf | %89 | /Volumes/nvme/Projects/远程Agent安卓 | 235x50 | 235x50 | 235x50 |  |
| ta-b7cc1c640ccf__p90.png | ta-b7cc1c640ccf | %90 | /Volumes/nvme/Projects/远程Agent安卓 | 235x50 | 235x50 | 235x50 |  |
| ta-b7cc1c640ccf__p96.png | ta-b7cc1c640ccf | %96 | /Volumes/nvme/Projects/远程Agent安卓 | 235x50 | 235x50 | 235x50 |  |
| ta-b7cc1c640ccf__p94.png | ta-b7cc1c640ccf | %94 | /Volumes/nvme/Projects/远程Agent安卓 | 235x50 | 235x50 | 235x50 |  |
| ta-b7cc1c640ccf__p95.png | ta-b7cc1c640ccf | %95 | /Volumes/nvme/Projects/远程Agent安卓 | 235x50 | 235x50 | 235x50 |  |
| ta-b7cc1c640ccf__p102.png | ta-b7cc1c640ccf | %102 | /Volumes/nvme/Projects/远程Agent安卓 | 235x50 | 235x50 | 235x50 |  |
| ta-b7cc1c640ccf__p103.png | ta-b7cc1c640ccf | %103 | /Volumes/nvme/Projects/远程Agent安卓 | 235x50 | 235x50 | 235x50 |  |
| ta-c4ef4f87d7a8__p5.png | ta-c4ef4f87d7a8 | %5 | /private/var/folders/45/xpp3dfrd3dsgh482sxfl_2f80000gn/T/ta-rs-mcp-sim-17159-1787442366010938000-0 | 80x24 | 80x24 | 80x24 |  |
| ta-c6b6848fcd95__p5.png | ta-c6b6848fcd95 | %5 | /private/var/folders/45/xpp3dfrd3dsgh482sxfl_2f80000gn/T/ta-rs-mcp-sim-99410-1787464422138382000-0 | 80x24 | 80x24 | 80x24 |  |
| ta-d31e15257fb9__p5.png | ta-d31e15257fb9 | %5 | /private/var/folders/45/xpp3dfrd3dsgh482sxfl_2f80000gn/T/ta-rs-mcp-sim-19194-1787463500756615000-0 | 80x24 | 80x24 | 80x24 |  |
| ta-e5ce5e44cecc__p5.png | ta-e5ce5e44cecc | %5 | /private/var/folders/45/xpp3dfrd3dsgh482sxfl_2f80000gn/T/ta-rs-mcp-sim-26951-1787442384251531000-0 | 80x24 | 80x24 | 80x24 |  |
| ta-e8878a711350__p0.png | ta-e8878a711350 | %0 | /Users/alauda/Documents/code/agent前沿探索/多agent协作 | 80x24 | 80x24 | 80x24 |  |
| ta-eb63cbe5b286__p0.png | ta-eb63cbe5b286 | %0 | /Volumes/nvme/Projects/tmux桌面端 | 137x42 | 137x42 | 137x42 |  |
| ta-eb63cbe5b286__p29.png | ta-eb63cbe5b286 | %29 | /Volumes/nvme/Projects/tmux桌面端 | 80x24 | 80x24 | 80x24 |  |
| ta-eb63cbe5b286__p28.png | ta-eb63cbe5b286 | %28 | /Volumes/nvme/Projects/tmux桌面端-judge | 235x50 | 235x50 | 235x50 |  |
| ta-f0d002797008__p1.png | ta-f0d002797008 | %1 | /private/var/folders/45/xpp3dfrd3dsgh482sxfl_2f80000gn/T/ta-hermetic-fts-red1-52382-0/workspace-fts-red1-1 | 80x24 | 80x24 | 80x24 |  |
| ta-f0d7a569c1de__p5.png | ta-f0d7a569c1de | %5 | /private/var/folders/45/xpp3dfrd3dsgh482sxfl_2f80000gn/T/ta-rs-mcp-sim-5653-1787463468600198000-0 | 80x24 | 80x24 | 80x24 |  |
| ta-f485b39b6a5d__p5.png | ta-f485b39b6a5d | %5 | /private/var/folders/45/xpp3dfrd3dsgh482sxfl_2f80000gn/T/ta-rs-mcp-sim-28934-1787442387244217000-0 | 80x24 | 80x24 | 80x24 |  |
| ta-ffdc525c5f83__p0.png | ta-ffdc525c5f83 | %0 | /Volumes/nvme/Projects/研究loopx | 235x50 | 235x50 | 235x50 |  |

verdict: pass