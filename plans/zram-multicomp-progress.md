# PVE ZRAM multi-comp 实施进度

## 阶段 0：证据与环境准备（2026-09-06）

**结论：当前环境的一轮有界证据探测已完成；G0–G3 均未闭合。** 未取得当前
目标的精确源码或实际 PVE 包/主机证据，因此不能宣称真实版本受支持，也不能认为
`-DCONFIG_ZRAM_MULTI_COMP` 对该目标安全。期间没有修改内核、swap、服务或仓库中
既有文件。此记录仅描述本轮可复核的发现和缺口，不构成实现、部署或生产环境认证。

### 基线

- 探测开始时工作树为 detached `HEAD`，基线提交为
  `e4e1a6d920843ae2b251f6e61b59c647440fcd5e`；随后协调者建立工作分支不改变此基线。
- 开始和结束时 `plans/` 都是未跟踪目录，且其中已有
  `plans/zram-multicomp-auto-update.md`。本轮在该既有目录新增本进度文件；不能将整个
  `plans/` 视为本轮新建或唯一仓库改动。
- `Makefile` 给出的目标为 `KERNEL_VER=7.0.14`、`KREL=16`、空
  `KREL_EXTRA`，即 `7.0.14-16-pve`。
- Ubuntu kernel 子模块 gitlink 为
  `68d75f0820869e33326712a9547550961795eaaf`，仍未初始化；本地
  `git show` 和 `git fsck` 均无法取得该对象。当前树也没有 `.config`、
  `debian/SOURCE` 或目标 `Module.symvers`。
- `.gitmodules` 中的上游为相对地址 `../mirror_ubuntu-kernels`。
- 计划与适用规则已读：`plans/zram-multicomp-auto-update.md` 及
  `/home/tanner/.codex/AGENTS.md`（要求以清晰中文响应）。

### G0：源码获取 — 未闭合

以下是本轮执行过的探测的**摘要**。原始终端逐行输出及每条命令的 shell 退出状态没有
保留，故此处不虚构它们；表中只记录当时观察到的关键响应。下表末列给出可复跑命令，
以便在网络条件相同或改善后重新取得带退出状态的证据。定点 fetch 被主动终止，不能
将其终止状态解读为“对象不存在”。

| 已执行探测（端点/对象） | 当时观察到的关键输出摘要 | 可复跑命令（会联网；定点 fetch 应设预算并自行中止） |
| --- | --- | --- |
| `git ls-remote https://git.proxmox.com/git/mirror_ubuntu-kernels.git` | 成功，返回官方 `jammy/master`、`lunar/master` 和标签。 | `git ls-remote https://git.proxmox.com/git/mirror_ubuntu-kernels.git` |
| `git ls-remote` 对 `https://git.proxmox.com/git/mirror_ubuntu-kernels.git` 的 `68d75f0820869e33326712a9547550961795eaaf` | 无输出；这不能证明该不可达对象不存在。 | `git ls-remote https://git.proxmox.com/git/mirror_ubuntu-kernels.git 68d75f0820869e33326712a9547550961795eaaf` |
| 官方镜像标签 `Proxmox-7.0.14-1` 与本库 PVE 提交 `f221849` 的 submodule 条目 | 标签为 `176218573332c6033483e6a89bc7a6695f645290`；`f221849` 的 gitlink 也为该值。它是不同于当前 `68d75f…` 的真实发布候选，不能替代。 | `git ls-remote --tags https://git.proxmox.com/git/mirror_ubuntu-kernels.git 'Proxmox-7.0.14-1'`; `git show f221849:submodules/ubuntu-kernel` |
| 临时探测仓库中的定点 `git fetch --depth=1 --filter=blob:none --no-tags`，对象 `68d75f…` | 服务器输出 `warning: filtering not recognized by server, ignoring`，随后尝试完整 pack（约 98,793 对象）；约 228 MiB 时主动终止，未取得 ref 或 commit。临时目录 `/tmp/pve-zram-source-probe-68d75f` 无可用源码。 | `git init /tmp/pve-zram-source-probe-retry && git -C /tmp/pve-zram-source-probe-retry fetch --depth=1 --filter=blob:none --no-tags https://git.proxmox.com/git/mirror_ubuntu-kernels.git 68d75f0820869e33326712a9547550961795eaaf:refs/heads/target` |
| Proxmox gitweb raw：`https://git.proxmox.com/?p=mirror_ubuntu-kernels.git;a=blob_plain;f=drivers/block/zram/Kconfig;hb=68d75f0820869e33326712a9547550961795eaaf`（以及同目录 `Makefile`、`zram_drv.c`、`Documentation/admin-guide/blockdev/zram.rst`） | 每个请求均为 HTTP 403。 | `curl -sS -o /dev/null -w '%{http_code}\\n' 'https://git.proxmox.com/?p=mirror_ubuntu-kernels.git;a=blob_plain;f=drivers/block/zram/Kconfig;hb=68d75f0820869e33326712a9547550961795eaaf'` |
| Launchpad Git 的 jammy/kinetic/lunar 列举（`git.launchpad.net`） | `Could not resolve host: git.launchpad.net`。 | `git ls-remote https://git.launchpad.net/~ubuntu-kernel/ubuntu/+source/linux/+git/jammy` |
| `git.kernel.org` 上游列举 | 可用，但不提供该 Ubuntu gitlink，不能作为源码身份替代。 | `git ls-remote https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git 68d75f0820869e33326712a9547550961795eaaf` |

尚未读取精确目标的 `drivers/block/zram/{Kconfig,Makefile,*.[ch]}`、版本 ZRAM
文档或全树 `CONFIG_ZRAM_MULTI_COMP` 引用。因此不允许采用模块局部宏、外部 Kbuild
或任何“仅影响模块内部”的推断。

### G1：包身份 — 未闭合

- 本环境没有实际 PVE/Proxmox kernel、signed kernel 或 headers 包可取样。
- `dpkg-deb`、`dpkg-query`、`apt` 与 `apt-cache` 均不存在，不能核对已发布包、
  `SOURCE`、签名仓库元数据或摘要。
- 已核对计划所引用的当前构建规则：`debian/SOURCE` 是构建时产生，不能将其在
  当前未构建工作树中缺失解释为包来源失败。

### G2：运行环境 — 未闭合

- 当前为 Fedora 44 QEMU 虚机：`7.1.13-200.fc44.x86_64`，
  `systemd-detect-virt=qemu`，不存在 `/etc/pve` 与 `/var/lib/pve-manager`，所以
  不是 PVE 测试/生产主机。
- `/dev/kvm` 存在、CPU 含 `vmx`、`qemu-system-x86_64 10.2.2`，可作为后续嵌套
  目标 VM 的基础；EFI 可用，GRUB 为 Fedora，`mokutil` 显示 Secure Boot disabled /
  Setup Mode。
- 当前 `/dev/zram0` 是 15.6G 活跃 swap，算法 `zstd`，使用 Fedora 内树签名的
  zram 模块；未对它执行任何操作。运行内核 build 链接存在，但
  `/lib/modules/$(uname -r)/Module.symvers` 缺失，且它不是目标 PVE headers。
- 用户新指定的 Dockur/Proxmox 方案仍在由协调者核实。尚未确认其运行模型；若它是
  共享宿主内核的容器，就不能把它当作独立 PVE kernel VM，也不能用它完成模块加载或
  启动链验证。本记录不将该方案计入 G2 证据。

### G3：并发安装 — 未闭合

- 缺少 PVE 的 apt/dpkg/initramfs 事务环境，尚未测试包管理锁、worker 重试或
  initramfs 并发。
- 可用工具：`make`、`gcc`、`git`、`curl`、`wget`、`qemu`、`modinfo`、`zramctl`、
  `mokutil`、`systemd-analyze`。`shellcheck` 与 `bats` 不存在。

### 文件与验证

- 本轮归属的变更文件：本文件 `plans/zram-multicomp-progress.md`；目录中原有的总计划
  文件不属于本轮新增。
- 未运行构建、模块、swap、包管理或主机服务变更命令。
- 有界网络探测没有形成可用源码快照；已停止而非继续全量下载。

### 下一阶段入口

阶段 1 可以独立开始**隔离 fixture** 的 resolver/manifest schema 和失败状态测试，
覆盖未知版本、缺失 `SOURCE`/headers、多个 `KREL` 修订。这些测试只能报告 fixture
覆盖，不能报告真实 PVE 包映射或模块支持。

要关闭 G0/G1，需取得一个可通过 `apt-secure` 或等效官方发布元数据验证的真实 PVE
kernel 与精确 headers 包样本及其 `SOURCE`，或取得可验证、可有界获取的官方 Ubuntu
源码快照。之后必须读取该目标的完整 ZRAM/Kconfig/依赖与文档，再评估配置宏。G2/G3
则需要可恢复 PVE VM 的启动、包事务和 initramfs 并发实测；当前 QEMU/KVM 仅提供
搭建该 VM 的基础条件。

## 阶段 1：精确目标解析器与固定夹具（2026-09-06）

**结论：固定夹具实现与聚焦测试完成；当时真实包身份 G1 尚未闭合。** 本阶段没有下载
源码、构建或安装模块，也没有执行 apt 事务。`7.0.14-16-pve` 仅为 fixture 中的精确
输入，`fixture-ready` 不是实际 PVE 包映射、精确源码可取得性、ABI 兼容性或启动测试
的声明。

### 基线与改动

- 基线为 `bd8cb4d`（阶段 0 文档）；实施结束时未创建提交。
- 新增 `tools/zram-multicomp/resolve.sh`、`lib/common.sh`、
  `manifest-schema.json`、`ensure-headers.sh`、README、
  `tests/test-resolve.sh` 和 `tests/fixtures/target-7.0.14-16/`。
- 原有 `tools/zram-multicomp/tests/vm/README.md` 未修改，属于并行 VM 工作，
  不在本阶段归属内。

### 冻结接口与行为

- resolver 输入为完整 `KVER`（保留 `KREL_EXTRA`）、架构、精确
  `kernel-package NAME=VERSION`、release manifest、解包目录、缓存目录与输出路径；入口
  目前必须显式传入 `--fixture`。成功和 `waiting-headers` target 会以
  `(KVER, architecture, package name, package version)` 的 SHA-256 键缓存为
  `target.json`。生产模式直接拒绝，直到实现受认证 apt 元数据的适配器。
- 同一 KVER 的不同 Debian 修订必须由完整 `NAME=VERSION` 区分；解析器要求唯一的
  kernel、headers 和 source mapping，未知、歧义或缺 `SOURCE` 都写出
  `unsupported`，不会猜测最近版本。
- `SOURCE` 按文本解析，不执行内容；它导出 PVE commit，随后选择固定的 Ubuntu
  gitlink、源码快照摘要和完整 patch 摘要清单。headers 仅在同一 KVER/架构且解包出的
  `.config` 与 `Module.symvers` 摘要匹配时为 ready。
- 缺失解包 headers 时输出 `waiting-headers` 和精确的 `package=version` 请求；
  `ensure-headers.sh` 是独立 CLI，拒绝在 dpkg maintainer script 中运行。无
  `--install` 时只打印命令；当前 fixture 环境不运行 apt。
- manifest 记录 KVER、架构、kernel/headers 包名、版本及摘要、signed 标记、PVE 与
  Ubuntu commit、patch/源码快照摘要、`.config`/`Module.symvers` 摘要，以及为后续
  阶段预留的 toolchain、vermagic、artifact 摘要字段。

### 信任边界与限制

- JSON 的 `trust.verified_by=apt-secure` 只保留为 fixture provenance，不能被
  resolver 当作信任根。未带 `--fixture` 的伪造 marker 被测试拒绝。
- 未来生产适配器须在 resolver 之前使用配置 keyring 让 `apt-secure(8)` 认证
  `InRelease`，校验 `Packages` 对签名 Release 的摘要，下载精确 deb 并形成不可由
  用户随意改写、且绑定包版本/SHA-256 的证据记录；然后从这两个 exact deb 提取
  `SOURCE`、`.config` 与 `Module.symvers`。旁路 SHA256 文件或手写 JSON 均不足够。
- 本环境没有实际 PVE kernel/headers 包、apt/dpkg 事务或目标源码快照；因此该适配器、
  实际签名仓库认证、真实 package/SOURCE 映射及 headers 自动安装只能留待 G1/G3
  环境完成。不得据此启动阶段 2 构建或宣称目标得到支持。

### 验证记录

- 通过：`bash -n tools/zram-multicomp/resolve.sh tools/zram-multicomp/ensure-headers.sh tools/zram-multicomp/lib/common.sh`
- 通过：`jq empty tools/zram-multicomp/manifest-schema.json tools/zram-multicomp/tests/fixtures/target-7.0.14-16/release.json`
- 通过：`tools/zram-multicomp/tests/test-resolve.sh`（输出 `resolver fixture tests passed`）
- 通过：`git diff --check`
- 测试覆盖精确 KREL/KREL_EXTRA、同 KVER 的不同包修订、signed kernel、未知版本、
  缺 `SOURCE`、缺解包 headers（退出 75 与精确 headers 请求）、多内核 fixture，及
  无 `--fixture` 的伪造 apt-secure JSON 标记。

### 下一阶段入口

阶段 2 仍被 G0/G1 阻塞：先取得经认证的实际 kernel 和 headers 包证据、实际
`SOURCE` 映射与精确 Ubuntu 源码快照，并读取目标 ZRAM/Kconfig/依赖后，才能消费
非 fixture target manifest。headers 安装的 apt/dpkg 锁、退避及并发行为属于 G3
验证，不能由本轮 CLI fixture 替代。

## 阶段 1 补充：真实受认证包证据（2026-09-06）

官方 `pve-test` 的精确 `7.0.14-16-pve` kernel 与 headers 已取得。适配器以显式
keyring 验证 `InRelease`，验证其中 `pve-test/binary-amd64/Packages.gz` 的 SHA-256，
再验证精确 deb 摘要、control 字段和解出的 `SOURCE`、`.config`、`Module.symvers`。
keyring 的来源及 SHA-256 记录在 `plans/zram-multicomp-evidence.md`；这不是带外公钥
固定的声明。`SOURCE` 给出 PVE commit `42c567d939ee67d2c610b55dca4569a6e6d8e4ea`，
只按数据解析。没有 apt 安装、内核、模块、服务或 swap 操作；headers 安装仍因 G3
未验证而禁用。
