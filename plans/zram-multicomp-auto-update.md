# PVE ZRAM multi-comp 自动更新实施计划

日期：2026-09-06。本文是实施计划，尚未安装模块、部署更新服务或开启定时任务。

## 执行与交接约定

按阶段 0 → 1 → 2 → 3 → 4 → 5 → 6 顺序实施。各阶段开始时先读该阶段引用的文档和代码；本文件中的接口示例与 CLI 是实施规格，不表示工具已经存在。当前状态：文档发现已完成一轮，目标源码和主机环境仍待核实；阶段 1–6 均未实施。

每阶段结束将交接记录写入 `plans/zram-multicomp-progress.md`（实施时创建）：基线 commit、改动文件、输入/输出格式、测试命令与结果、未解决事项、下一阶段入口。单元测试使用固定 fixture；涉及模块加载、swap、apt、initramfs 的验证在可恢复 PVE VM 中进行。前一阶段未满足出口条件时，后续可编写隔离 fixture，但不能声明真实系统支持已完成。

第一版范围：amd64、一个真实可取得并验证的 PVE 系列、官方内核保持不变。上游启用原生 multi-comp、跨系列适配与 Secure Boot 分别有独立分支。目标主机版本、仓库 channel、ZRAM 管理者和启动链由实施阶段读取环境确定，不能从本仓库版本推断宿主正在运行的内核。

## 目标与架构决定

保留官方 PVE 内核包，为每个目标内核单独生成开启 `CONFIG_ZRAM_MULTI_COMP` 的 `zram.ko`。内核升级后自动准备模块，重启进入目标内核后自动应用压缩配置并验证生效。

核心规则：**跟随目标内核取对应的 ZRAM 源码，而不是让同一份旧源码一直跨版本重编。** DKMS 可以执行构建，但不会自动处理源码溯源、PVE 补丁、未来 API 变化或运行时配置。因此第一版采用专用更新器与 Kbuild，不额外套 DKMS。

推荐路径：经过验证的精确版本预编译产物优先；没有产物时，使用同一套构建器在主机上编译。是否允许本机编译可配置，默认启用并限制 CPU、内存和运行时间。CI 与主机共享源码解析和验证逻辑。

验证等级单独记录为 `validation_level`：本机只完成构建与 ABI 检查的产物是 `static`；经过对应目标内核 VM 启动测试的产物是 `boot-tested`。已验证系列内的新 ABI 可本机编译，安装后保持 `ready-for-boot`，直到真实启动检查成功才成为 `active`；这不等于该二进制在安装前已经做过 VM 测试。新系列仍须先完成阶段 2、6 的资格验证。要求每个二进制预先经过 VM 测试的部署，应配置仅接受 `boot-tested`，未有匹配产物时等待。

```text
安装/升级 PVE kernel
  → kernel postinst 记录目标 KVER，快速返回
  → 独立 worker + 定时补扫已安装内核
  → 核实目标内核/包版本/架构与原厂 ZRAM 能力
      ├─ 原厂已支持 multi-comp → 使用原厂模块
      └─ 需要 override
          → 有可信且完全匹配的预编译产物？
              ├─ 有 → 下载并验证
              └─ 无 → 等待精确 headers/源码 → 本机隔离构建并验证
          → 必要时本机签名 → 原子安装 → depmod → 更新目标 initramfs
  → ready-for-boot（不自动重启，不热替换正在使用的模块）
  → 重启 → 配置主/次算法 → 启用 swap → 验证 multi-comp
  → active
```

自动化承诺限于已验证的兼容范围。7.0 → 7.1 → 7.2 使用各自源码能解决大部分源码 API 同步问题，但不能保证未来驱动永远可单独构建；若出现未导出符号、跨模块配置依赖或 Kbuild 改动，必须停止发布该 override、记录原因并保留官方内核可启动。默认不阻止官方内核安全更新；因此准备失败或过早重启时，可能暂时只有普通 ZRAM。

## 阶段 0：文档与现状核实

已核实的事实：

- 当前工作树 `e4e1a6d920843ae2b251f6e61b59c647440fcd5e`，目标版本由 `Makefile:4-25` 组成，为 `7.0.14-16-pve`；必须保留 `KREL_EXTRA`，不能只匹配 `7.0.14`。
- [PR #1](https://github.com/tanner-chiang/pve-kernel/pull/1) 当前为 CLOSED；实现保存在 `origin/automation/zram-multicomp` 的 `9e3c3d0538b0c9825ee00a0c8eb39250b4845a25`，当前工作树没有这些脚本。它可作为实现参考，不视为已部署能力。
- 该分支 `tools/zram-multicomp/build.sh` 已实现 PVE revision → Ubuntu gitlink → PVE patch stack → 官方 headers → 外部模块构建；`install.sh`/`uninstall.sh` 已有 override、depmod、initramfs 与部分回滚逻辑。
- 该分支 `.github/workflows/zram-multicomp.yml` 默认跟踪 upstream master，每六小时检查；尚不能覆盖所有在用系列，也没有主机自动安装或运行时重压缩配置。
- `debian/proxmox-kernel.postinst.in:14-22` 使用 `run-parts --exit-on-error` 执行 `/etc/kernel/postinst.d`，参数为目标 KVER 与内核镜像路径。hook 返回失败会使内核包配置失败。
- 当前 `debian/proxmox-headers.postinst.in:1-60` 没有执行 `/etc/kernel/header_postinst.d`；`debian/control.in` 没有保证具体 kernel/headers 的相互安装顺序。不能只依赖 DKMS 的双 hook。
- `Makefile` 的 `debian.prepared` 目标生成 `debian/SOURCE`，记录 PVE commit；`debian/rules:63` 将 SOURCE 安装进包文档。可优先从目标包实际文档解析来源，但须核实 signed 包与文档布局。
- `debian/rules:181-223` 准备 headers 并提供 `.config`、`Module.symvers`、生成头文件及 `/lib/modules/<KVER>/build` 链接。

固定参考代码均来自上述 PR commit，实施时用 `git show <commit>:<path>` 读取；分支名称只用于定位，不作为可变输入。可复制模式的位置：

| 参考编号 | 必须读取的片段 | 可复用模式与边界 |
| --- | --- | --- |
| R1 | PR `tools/zram-multicomp/build.sh:28-47`；当前 `Makefile:99-124` | KVER/gitlink 与 SOURCE/patch 顺序；新增从目标包反查 commit 的逻辑 |
| R2 | PR `build.sh:55-110`；当前 `debian/rules:181-223` | headers 解包、固定源码与 ZRAM 提取；下载信任链和包修订匹配须补齐 |
| R3 | PR `build.sh:112-143` | 外部 Kbuild、局部宏、vermagic/CRC；仅作候选模式，先完成精确源码门槛 |
| R4 | PR `install.sh:60-99`、`uninstall.sh:25-65` | depmod、解析路径、initramfs、回滚顺序；补齐幂等和原子替换 |
| R5 | 当前 `debian/proxmox-kernel.postinst.in:14-22`、`debian/proxmox-headers.postinst.in:1-60` | hook 调用契约与 headers hook 缺失；安装自有 hook，无需修改 PVE 模板 |
| R6 | PR `.github/workflows/zram-multicomp.yml:127-255` | build/artifact/publish 分层；新增版本矩阵和 VM 测试门槛 |
| R7 | 当前 `Makefile:103-104`、`debian/rules:58-67`、`debian/signing-template/rules.in:41-45` | unsigned/signed 包均有 SOURCE 安装规则；实际包内路径和压缩形式仍需读取包确认 |

允许使用的接口及参考：

| 接口/模式 | 来源与用途 |
| --- | --- |
| `make -C "$KDIR" M="$MODSRC" modules` | [Kbuild 外部模块文档](https://docs.kernel.org/kbuild/modules.html)，构建目标内核的模块；`modules_prepare` 不会生成所需的 `Module.symvers` |
| kernel hook 的 `$1` / `$2` | 仓库 kernel postinst，分别是目标版本与镜像路径；不能用 `uname -r` 替代升级目标 |
| `depmod -a "$KVER"`、`modinfo -k "$KVER" -n zram` | PR 分支 install/uninstall 脚本，重建索引并检查实际解析路径 |
| `update-initramfs -u -k "$KVER"` | PR 分支安装模式；还需在 PVE VM 验证 boot-tool 的 ESP 同步链 |
| `scripts/sign-file <hash> <private-key> <certificate> <module>` | [内核模块签名文档](https://docs.kernel.org/admin-guide/module-signing.html)，签名后不得再 strip |
| `comp_algorithm`、`recomp_algorithm`、`recompress`、`idle` | [ZRAM 文档](https://docs.kernel.org/admin-guide/blockdev/zram.html)，第二算法配置与重压缩由用户态控制 |
| `compression-algorithm = lz4 zstd` | [zram-generator v1.2.1 配置文档 72–83 行](https://github.com/systemd/zram-generator/blob/v1.2.1/man/zram-generator.conf.md#L72-L83)，算法列表；[setup.rs 32–133 行](https://github.com/systemd/zram-generator/blob/v1.2.1/src/setup.rs#L32-L133) 先写主/次算法，再 disksize |
| `OnBootSec=2min`、`OnUnitInactiveSec=15min`、`RandomizedDelaySec=1min` | [systemd v257 timer 文档](https://github.com/systemd/systemd/blob/v257/man/systemd.timer.xml)，开机触发与每次完成后约 15 分钟补扫；`Persistent=` 仅适用 OnCalendar |
| oneshot 的 `TimeoutStartSec=`；`CPUQuota=`、`MemoryHigh=`、`MemoryMax=`、`TasksMax=` | [v257 service 文档](https://github.com/systemd/systemd/blob/v257/man/systemd.service.xml)、[resource-control 文档](https://github.com/systemd/systemd/blob/v257/man/systemd.resource-control.xml)；`RuntimeMaxSec=` 不限制 oneshot，周期 worker 不设 RemainAfterExit |

补充核实：[DKMS v3.2.2 autoinstaller](https://github.com/dkms-project/dkms/blob/v3.2.2/dkms_autoinstaller.in) 在缺少目标 headers 时跳过，有 headers 时执行 autoinstall 并传播构建失败；它并不解决本仓库 headers hook 未执行的问题。[Debian Kernel Handbook §8](https://kernel-team.pages.debian.net/kernel-handbook/ch-update-hooks.html) 说明 kernel/initramfs hooks 的参数与执行约定；hook 不读取 stdin，诊断写 stderr，避免使用保留给 bootloader 的 `zz-` 前缀。

实施前的证据门槛：读取每个目标 commit 的 `drivers/block/zram/{Kconfig,Makefile,*.[ch]}` 和对应版本 ZRAM 文档，并检查全源码树的 `CONFIG_ZRAM_MULTI_COMP` 引用、Kconfig depends/select、条件对象与对外结构/符号，确认算法后端及外部依赖。此前精确源码的 GitHub raw 请求返回 404、Proxmox gitweb 请求返回 403，本轮官方 gitweb 仍返回 403，尚未验证该目标源码；不能把 PR 中“只影响模块内部”的注释当成跨版本保证。实现时须通过可用的官方 Git 获取或已核实来源的源码包完成此项。

阶段 0 交付与门槛：

| 项目 | 当前证据 | 实施前要补齐的结果 |
| --- | --- | --- |
| G0 源码获取 | 本地 submodule 为空、精确对象不可用，gitweb 再核实仍为 403 | 一个真实发布目标的可信源码快照、gitlink 身份、ZRAM/Kconfig 影响范围记录；必要时改选可取得目标并明确支持范围 |
| G1 包身份 | R1/R7 给出 SOURCE 生成及安装规则 | 一个实际 kernel、signed kernel（适用时）、headers 包的版本/来源/摘要对应样本 |
| G2 运行环境 | 尚未连接目标 PVE 主机 | PVE/内核/headers 版本、架构、仓库、Secure Boot、boot-tool/GRUB、现有 ZRAM 管理器及配置清单 |
| G3 并发安装 | PVE hook 同步传播错误；timer 可补扫 | apt/dpkg 与 initramfs 并发测试结果，确认具体锁与重试实现后才能启用安装 worker |

规避事项：精确源码无法读取只能记为未验证；发行分支名称和上游最新文档不能代替目标版本证据。当前计划可供逐阶段实施，尚不构成模块构建成功或生产环境兼容性认证。

## 阶段 1：建立精确版本与源码解析器

实现文件：`tools/zram-multicomp/resolve.sh`、`lib/common.sh`、manifest 格式定义。

输入：阶段 0 的 G1 包样本，以及 `KVER + architecture + kernel package identity`。输出：经格式校验的 `target.json` 与缓存目录；字段在本阶段冻结，后续阶段只消费该结果。

1. 复用 PR 的版本读取、gitlink 与 patch stack 模式，输入改为目标 `KVER`，不默认使用 upstream master。
2. 从已安装内核包、包文档 SOURCE 与官方发布元数据建立映射：KVER、架构、Debian package version → PVE commit → Ubuntu gitlink → 完整 PVE 补丁序列。SOURCE 是查找依据，仍须与实际发布包核对；同 KVER 的不同包修订不能随意合并。
3. headers 必须属于同一目标构建；优先使用主机已安装且匹配的 headers。缺失则进入等待状态，由独立的依赖安装步骤在包管理器可用时安装精确包，绝不在 kernel hook 内嵌套 apt。
4. 自动安装 headers 的步骤仅安装所需精确版本，避免触发额外全系统升级；锁冲突或包尚未发布时退避重试。可信预编译路径在不需要本机签名工具时可不依赖本机 headers。
5. manifest 记录 KVER、架构、内核与 headers 包版本/摘要、源码 commits、patch 摘要、官方 config/Module.symvers 摘要、工具链身份、构建器版本、完整 vermagic 与产物摘要。
6. 以官方签名仓库元数据或受信任的发布 manifest 验证下载来源。旁边放一个 SHA256 文件只能校验一致性，不能独立证明来源可信。

文档与复制入口：先读 R1、R2、R7，复制其版本、gitlink 与 headers 文件布局模式；官方仓库验证以目标系统 `apt-secure(8)` 为准。SOURCE 文本按数据解析，不执行其中命令。

验收：同一 KVER 解析可重复；覆盖 KREL_EXTRA、多包修订、signed 包、未知版本、缺少 SOURCE/headers、多个已安装内核。找不到唯一可信映射必须等待或标记不支持，不能猜测“最接近版本”。

出口/交接：提交 `target.json` schema、一个真实目标和失败场景 fixtures，以及解析测试结果。规避事项：不能只按 upstream 版本或 KVER 选包；未认证的索引摘要不能充当信任根。

## 阶段 2：实现随源码版本变化的构建器

实现文件：`tools/zram-multicomp/build.sh`、`verify.sh`；必要时添加按已验证系列划分的最小适配文件。

输入：阶段 1 的 target manifest、G0 核实过的源码、官方 headers。输出：`zram.ko`、`build.json`（包含目标 manifest 摘要、工具链身份、产物摘要和验证等级）、完整构建日志；本阶段不安装主机模块。

1. 在临时工作目录获取固定源码 commit，按顺序应用固定 PVE patch stack，再提取完整 ZRAM 目录和经过核实的构建依赖。浅克隆仍可能传输完整内核树，须设磁盘/下载预算并缓存可信快照，不能把 `--depth=1` 当成只下载 ZRAM 的保证。获取失败进入 `waiting-source`，读过源码后证实不兼容才进入 `unsupported`。
2. 从目标源码 Kbuild 保留对象文件与算法后端选择，仅做经过验证的外部模块入口调整。Kbuild 结构不符合预期时明确失败，不能盲目追加 `obj-m` 掩盖变化。
3. 按目标 Kconfig 核实 multi-comp 的依赖，检查 `CONFIG_ZRAM=m`、所需算法、zsmalloc 和符号导出。若 ZRAM 为 built-in 且未启用所需功能，override 路径不适用。
4. 只有确认配置差异局限在 ZRAM 模块内部后，才使用 PR 的模块局部宏开启模式；若还涉及 Kbuild 条件，须显式处理并验证。不得修改官方 headers 的全局配置，伪装 ABI 一致。
5. 复用官方 `.config`、生成头文件与 `Module.symvers`，以 `make -C "$KDIR" M="$MODSRC" ... modules` 构建。工具链按目标构建信息选择，不能永久写死 gcc-14。
6. 验证 ELF 架构、完整 vermagic 与目标官方构建的一致性、导入符号 CRC、依赖模块和功能编译结果；`modprobe --dump-modversions` 等检查失败不得当成空结果通过。静态 ABI 检查不能替代启动加载测试。
7. 同系列更新也重读目标源码；新系列先跑适配和启动验证，成功后加入支持范围。未通过的系列保持 `unsupported`，不自动扩大配置改动或替换 zsmalloc 等其他模块。

文档与复制入口：读 R2、R3 和目标 `drivers/block/zram/Kconfig`、`Makefile`，按 [Kbuild 文档的 Command Syntax / Module Versioning](https://docs.kernel.org/kbuild/modules.html) 复制构建命令及符号校验模式。目标源码与配置证据先于宏修改。

验收：至少两个实际发布的相邻 PVE ABI 均使用各自源码成功构建；一个可取得的新系列完成跨系列验证。覆盖 headers/符号不匹配、缺少 backend、工具链不兼容和源码入口变化。未有可测的新系列时只声明已测范围。

出口/交接：至少一个真实目标构建成功后才能进入安装集成；首个系列自动更新支持还需第二个相邻 ABI 的结果。交付逐目标构建报告和支持矩阵，新系列可继续标为待验证。规避事项：不使用跨内核复用模块、强制加载、伪造 vermagic，或将 modpost 未解析符号降为可忽略警告。

## 阶段 3：可回滚安装与 Secure Boot

实现文件：`tools/zram-multicomp/install.sh`、`uninstall.sh`、`sign.sh`。

输入：阶段 2 的模块与 build manifest、G2 VM 环境；输出：原子安装/回滚接口与每目标安装记录，包含签名前后摘要、boot ID 和安装时间。安装信任策略与验证等级独立，不能将“已签名”视为“已启动验证”。

1. 在 PR 脚本基础上实现可重复安装和相同 KVER 的模块修订升级；自有路径仍是 `/lib/modules/<KVER>/updates/pve-zram-multicomp/zram.ko`。不得覆盖原厂 `kernel/drivers/block/zram/zram.ko*`。
2. 使用每版本锁、临时文件和原子 rename；提交前校验 manifest、目标包身份、产物、签名与当前包状态。更新失败恢复此前 override；首次安装失败回到原厂。
3. 下载/编译在低权限 worker 中执行；root 安装步骤只消费经过验证的文件与结构化元数据，不能 `source` 下载的 metadata 或直接执行随包下载的任意安装脚本。
4. Secure Boot 或目标内核强制签名时，使用主机已登记受信任证书的私钥签名。不能只检查 `modinfo signer` 非空；结合证书登记检查与实际目标内核加载验证。首次 MOK 登记可能需要人工在固件界面完成，此前状态为 `needs-key`，之后可自动签名。
5. 依次 `depmod -a "$KVER"`、检查解析路径、更新目标 initramfs；核实 initramfs 内没有旧副本，以及适用的 PVE ESP 同步链成功。所有步骤完成才标记 `ready-for-boot`。
6. 当前模块已加载时仅更新磁盘文件，标记需要重启；不调用自动 `swapoff`、`rmmod` 或 device reset。磁盘 `modinfo` 路径不能证明当前内存中已加载新模块。
7. 卸载只移除本工具拥有的 override 并重建索引/镜像。回滚自身失败时保留恢复资料，状态为 `repair-required`，不能报告成功。

文档与复制入口：读 R4，复制其目标版本参数和刷新顺序；按 [模块签名文档的 Manually signing modules / Loading signed modules](https://docs.kernel.org/admin-guide/module-signing.html) 实现签名。先读取目标 PVE 的 initramfs post-update hooks，再决定是否需要额外 ESP 同步，避免重复执行整套 kernel hooks。

验收：首次安装、重复安装、同 KVER 修订、回滚、卸载；注入 depmod、initramfs、磁盘空间和签名失败；Secure Boot 开/关 VM 分别完成加载测试。确认更新中正在运行的 swap 不受改动。

出口/交接：交付安装 journal 格式、故障注入结果及 VM 回滚记录。规避事项：不自动卸载正在使用的模块；`signer` 非空和磁盘文件存在均不能替代加载/信任验证。

## 阶段 4：自动更新协调器

实现为独立 `pve-zram-multicomp` Debian 包，提供本地 CLI、kernel hook、systemd worker/timer；不要混入官方 kernel 包的维护脚本。建议文件放在 `tools/zram-multicomp/packaging/`。

输入：阶段 1–3 的冻结接口及 G3 并发验证方案；输出：可安装 `.deb`、CLI、持久状态与服务单元。构建缓存放 `/var/cache/pve-zram-multicomp/`，状态和恢复记录放 `/var/lib/pve-zram-multicomp/`，管理员设置放 `/etc/pve-zram-multicomp/`；状态必须能在 worker 崩溃后恢复。

1. `/etc/kernel/postinst.d/pve-zram-multicomp` 只记录 `$1` 并请求异步检查，非阻断返回。入队失败须记录明显诊断，timer 仍可重建工作清单。
2. 配套 `/etc/kernel/header_postinst.d/pve-zram-multicomp` 作为可选加速入口；可靠性依靠开机及每轮完成后约 15 分钟扫描已安装 PVE 内核/headers，覆盖本仓库没有执行 headers hook 的情况。复制阶段 0 的 timer 参数，oneshot worker 显式设置 `TimeoutStartSec=`，CPU/内存配额依据 G2 VM 的测量定值。
3. worker 的下载/构建可在包事务外独立排队，最终安装须在相关包已配置、包管理锁可协调时执行，并重新核实目标身份；initramfs 修改也必须串行。按 [Debian Dpkg FAQ 的锁说明](https://wiki.debian.org/Teams/Dpkg/FAQ) 验证 region-lock 语义；本工具的 flock 只用于自身任务互斥，不等于持有 dpkg 的锁。不删除锁文件、不仅检查进程名、不持自建包管理锁再启动 apt。具体实现与真实包管理进程的竞态在 G3 验证后定稿。
4. 优先获取精确匹配且已通过发布验证的预编译产物；缺失时自动走阶段 1、2 的本机构建。构建目录使用内容寻址缓存；源码下载或构建失败有退避、次数/时间预算与日志。
5. 默认处理所有仍安装的受支持 PVE 内核，含运行内核和将要启动的内核；清理随已移除内核对应的自有缓存/override，不删除其他模块或内核。
6. 原厂 config 与实际启动能力表明已原生支持时走 `native` 路径，并有控制地撤销旧 override；不能因为当前已加载的自定义模块存在 sysfs 节点就误认原厂支持。
7. 不自动重启、不默认 pin 内核。发布延迟、构建失败或重启过早可回退普通 ZRAM，但必须显示功能降级及具体原因。管理员维护流程可在重启前检查 readiness。

拟定 CLI（待实现，不是当前可执行命令）：

```text
pve-zram-multicomp status [--json]
pve-zram-multicomp ensure --kernel <KVER>
pve-zram-multicomp retry --kernel <KVER>
pve-zram-multicomp rollback --kernel <KVER>
```

每个 KVER 分开记录部署与运行状态，避免同一 KVER 的旧修订仍在运行时，被新磁盘文件覆盖状态：

| 字段 | 取值/含义 |
| --- | --- |
| `deployment` | pending、waiting-headers、waiting-source、building、needs-key、ready-for-boot、native、unsupported、failed、repair-required |
| `runtime` | inactive、active、degraded、unverified；非当前运行内核为 inactive |
| `desired_build_id` / `installed_build_id` / `loaded_build_id` | 分别表示期望、磁盘安装和可证明的运行身份；无法证明 loaded 身份时为 null |
| `reason` / `retry_after` / `validation_level` / `observed_boot_id` | 错误与重试信息、验证等级、当前启动证据 |

严格验证策略缺少 boot-tested 产物时使用 pending 加明确原因。同一目标可同时是 deployment=ready-for-boot、runtime=active（运行旧 build）；CLI 必须显示二者的 build 身份。sysfs 能力只能证明功能存在，不能推断 loaded_build_id；无法核实加载身份时显示 unverified 和已确认的功能探测结果。

文档与复制入口：读 R5、[Debian Kernel Handbook §8](https://kernel-team.pages.debian.net/kernel-handbook/ch-update-hooks.html)、上述 Dpkg FAQ；systemd 单元按目标版本的 `systemd.service(5)`、`systemd.timer(5)`、`systemd.resource-control(5)` 编写。自有 hook 复制参数约定，不复制 kernel postinst 的同步长任务模式。

验收：kernel 先装/headers 后装、headers 先装、同一 apt 事务装多个内核、离线后恢复、无 CI 产物、本机编译禁用、worker 中断重启、重复触发、内核移除与立即重启。构建失败不使 PVE kernel 包停在未配置状态。

出口/交接：交付 package 安装/升级/移除测试、每个状态的触发与重试规则、apt/initramfs 竞态结果。规避事项：timer 补扫是可靠性来源，header hook 只作加速；dpkg trigger 即使采用也只是入队事件，不是整个 apt 事务完成信号。

## 阶段 5：开机配置与实际重压缩

实现文件：运行时配置适配器、配置示例、验证命令与可选重压缩 service/timer。

输入：阶段 3 的安装记录、阶段 4 的状态 API、G2 管理器信息；输出：一个管理者控制的设备生命周期、重压缩配置与运行健康报告。先支持目标环境实际使用的管理器，未知管理器只报告需要配置，不能同时启动第二套 swap 管理服务。

1. 先发现目标主机已有的 ZRAM 管理者（如 systemd-zram-generator、zram-tools 或自定义 unit），只由一个管理者创建设备、设定大小和启用 swap。保留已有容量、优先级及设备用途。
2. 在初始化 disksize 和 swapon 前配置算法；建议默认主算法 `lz4`，次算法 `zstd`、priority 1，前提是目标实际支持这些后端。已有明确用户设置优先。
3. 首选已核实的 zram-generator v1.2.1 多算法模式：在现有 `[zram0]` 配置中合入 `compression-algorithm = lz4 zstd`，保留容量等其余设置。该版本在 disksize 前配置第二算法；[generator.rs:238-249](https://github.com/systemd/zram-generator/blob/v1.2.1/src/generator.rs#L238-L249) 为 swap unit 设置 setup service 的 Requires/After。v1.1.2 文档只支持单算法，遇到旧版或其他管理器时单独确认适配/升级路径，不能套用多算法配置或泛用前置 hook。禁止重启活动的 setup service 来应用更新，其 ExecStop 会 reset 设备。
4. 首版自动重压缩策略采用独立 timer 定时、限量处理 huge pages；可从每轮结束后约 15 分钟、每次最多 4096 页起步，在测试 VM 测量 CPU/延迟后再确认默认值。`max_pages` 等参数仅在目标接口支持时使用；页数预算不等于严格执行时间上限，service 超时也不能保证立即中断内核同步重压缩。生成器的算法参数不是周期重压缩任务。
5. 示例接口：`echo 'algo=zstd priority=1' > /sys/block/zramX/recomp_algorithm`；运行中按目标文档使用 `echo 'type=huge priority=1 max_pages=4096' > /sys/block/zramX/recompress`。这不是此次会执行的命令。
6. cold/idle 策略作为后续可选项：区分支持按访问时间判断的配置与手动 idle 标记；没有活动时间跟踪时，先标记、等待观察期再重压缩，不能把刚标记的所有页面立即称为冷页面。
7. 未就绪时保留普通 ZRAM 可用并报告降级；不把模块安装成功视为实际执行了重压缩。启动检查包含第二算法、sysfs 能力、swap 配置及错误日志；重压缩没有节省空间本身不等于失败。

文档与复制入口：读阶段 0 的目标 ZRAM 文档、固定 zram-generator v1.2.1 `man/zram-generator.conf.md:72-83`、`src/setup.rs:32-133`、`src/generator.rs:238-249`，复制简单算法列表与已有启动依赖。再与 G2 实际安装版本的 man/unit 核对；旧版依据 [v1.1.2 配置文档](https://github.com/systemd/zram-generator/blob/v1.1.2/man/zram-generator.conf.md#L65-L73) 进入兼容分支。

验收：配置在 swapon 前生效；负载下实际触发重压缩、读回数据一致、无内核告警。验证已有 swap 管理器不会重复创建设备，回退原厂时普通 swap 仍正常，忙碌设备更新无需 swapoff。

出口/交接：交付管理器版本与配置样例、启动顺序证据、重压缩/数据一致性结果和 active 判定规则。核实目标内核是否有可用的加载 build 身份接口；没有可靠证据就保留 loaded_build_id=null、runtime=unverified，不虚构身份读取 API。规避事项：仅检查 sysfs 文件或磁盘 modinfo 不足以确认本次安装已经加载；同次启动已经加载的旧模块不得在安装后被标记为新 build active。

## 阶段 6：CI、跨版本验证与上线

输入：阶段 1–5 的实现与测试记录；输出：支持矩阵、VM 启动测试报告、不可变发布产物和完整部署/恢复操作文档。发布/部署动作在实施任务中执行，本次只准备规格。

1. 复用现有 workflow，但以官方仓库已发布 kernel/headers 清单与明确支持系列生成矩阵，不能只看 master 最新 commit。允许同 KVER 发布不同构建器修订，产物身份不可覆盖混淆。
2. 第一批支持 amd64 与实际在用 PVE 系列；arm64 单独验证后启用。记录 distribution/channel、架构、KVER 和源码身份，禁止跨条目复用模块。
3. 每个发布产物先通过静态检查，再在启动对应官方内核的 VM 验证加载、multi-comp 配置、重压缩及数据完整性；新系列须额外验证源码提取和 Kconfig 影响范围。普通 CI 容器无法替代目标内核加载测试。
4. 发布可信 manifest 与不可变产物；主机先验证来源和精确目标身份，再签名/安装。新系列未通过验证不得成为主机自动构建的已支持目标。
5. 集成矩阵覆盖阶段 1–5 的故障与安装顺序案例，以及 stock 已原生支持、Secure Boot、GRUB/PVE boot-tool 适用启动链、initramfs 中已含 stock ZRAM。
6. 先在可回滚 VM 跑一次完整的“旧内核 active → apt 更新 → 新内核 ready → 重启 → active → rollback”流程，再进行单节点试用；保留原先可启动的官方内核。

文档与复制入口：读 R6，复制 build/artifact/publish 分离模式；逐项对照阶段 0 的 Kbuild、签名、kernel hook 和目标版本 ZRAM 文档审查实现，所有新增第三方选项须给出实际版本依据。

验证清单：

- [ ] 对 shell 入口执行 `bash -n` 和 ShellCheck，对 unit 执行目标系统的 `systemd-analyze verify`；使用实际新增文件列表，不让缺失文件被通配符静默跳过。
- [ ] 运行 resolver、manifest、状态机、幂等安装与故障恢复测试，保存真实结果；fixture 成功不能代替实际模块构建成功。
- [ ] 用 `rg` 审查目标选择路径中的 `uname -r`、强制加载选项、下载 metadata 的 `source`、自动 swapoff/rmmod、`|| true` 和盲目追加 `obj-m`；逐处核实用途，不能仅凭关键词出现判失败，也不能吞掉验证错误。
- [ ] 用对应官方内核启动 VM，确认 ABI/签名加载、第二算法配置、重压缩返回值、数据读回一致及无新增内核错误。
- [ ] 演练两个相邻 ABI 更新、跨系列不支持与恢复、原生 multi-comp、Secure Boot、离线重试、headers 晚到和安装回滚。
- [ ] 将报告中的每个“支持”条目绑定具体目标身份和证据；未测试条目维持 pending/unsupported，不能以预算或 CI 不可用为由标记完成。

规避事项：CI runner 的当前内核无法证明目标 PVE 内核兼容；本机 static 构建不冒充 boot-tested 发布产物；预编译包来源认证与目标主机模块签名分别验证。

最终验收标准：

- 一次安装更新器后，在已支持范围内升级 PVE kernel，无需手动找源码、改版本、编译或复制模块。
- 新模块确实来自该目标内核对应的 PVE 源码与补丁，ABI 静态检查和运行验证均通过。
- 新内核准备就绪后重启，第二算法配置和重压缩任务自动生效；可用一条 status 命令区分待准备、待重启、生效和降级。
- 构建/API/网络/签名检查失败须保留官方内核包、原厂模块和正在使用的 ZRAM；通过故障注入验证恢复过程。新模块的运行时缺陷不能由静态检查排除，须如实保留验证等级与启动测试结果。
- 只有上述完整链路被验证，才称为“自动更新完成”。当前阶段仅完成计划与资料核实。

后续可选路线：若某系列无法安全单独构建 ZRAM，再评估自动重建整个 PVE kernel 并在其配置中启用 multi-comp；这会引入完整内核维护与签名成本，不作为第一版隐式回退。若官方开始原生开启该功能，应优先停止维护对应 override。
