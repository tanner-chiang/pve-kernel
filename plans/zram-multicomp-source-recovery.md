# G0：精确 Ubuntu 内核来源恢复

采集时间：2026-09-06。此记录只恢复并审计由精确 PVE 包声明的 Ubuntu 子模块；没有
构建内核、安装包或改变主机配置。

## 结论

已取得完整且可离线读取的精确源码对象。PVE `7.0.14-16-pve` 包中的 `SOURCE` 文件
指定 PVE 提交 `42c567d939ee67d2c610b55dca4569a6e6d8e4ea`；此前的包证据已将其子模块
gitlink 固定为 `68d75f0820869e33326712a9547550961795eaaf`。该对象也是 Proxmox 官方
`mirror_ubuntu-kernels` 中公开注释标签 `Ubuntu-7.0.0-31.31` 的 peeled commit。

精确源码中的 `drivers/block/zram/Kconfig` 定义了 `CONFIG_ZRAM_MULTI_COMP`，其帮助
文本说明它启用多压缩流和重压缩；源码还以 `#ifdef CONFIG_ZRAM_MULTI_COMP` 编译
`recomp_algorithm` 与 `recompress` 相关 sysfs 接口。与之配对的精确
`proxmox-headers-7.0.14-16-pve` 包配置（见既有 G1 证据）明确为：

```
# CONFIG_ZRAM_MULTI_COMP is not set
```

因此，对这个**已发布的精确 ABI**，多压缩/重压缩接口没有被编进 `zram.ko`；源码存在该
功能不改变这个配置结论。

## 恢复方法与为什么先前失败

官方镜像 URL：

```
https://git.proxmox.com/git/mirror_ubuntu-kernels.git
```

先前 fetch 直接请求未公告的 commit SHA。虽然服务端接受请求，但它忽略 filtering，发送
完整历史（11,452,468 对象），故在 2.35 GiB 时停止。该行为记录在：

```
/home/tanner/.cache/pve-zram-evidence/fetch-68d75f.log
```

本次先用 `git ls-remote` 确定公开标签与目标的映射：

```
017716980931abce2f579475e31510a90f8cb65c refs/tags/Ubuntu-7.0.0-31.31 peeled:68d75f0820869e33326712a9547550961795eaaf
```

随后在独立缓存目录执行：

```
git -c protocol.version=2 -C repo fetch --no-tags --depth=1 --filter=blob:none \
  origin 'refs/tags/Ubuntu-7.0.0-31.31:refs/tags/Ubuntu-7.0.0-31.31'
```

服务器同样报告 `filtering not recognized by server, ignoring`，但这次 `deepen 1` 与
已公告 tag 限定了传输范围：得到 98,794 个对象、274.29 MiB pack、总目录约 275 MiB，
在约 1 分钟内完成，远低于 2 GiB/10 分钟上限。协议和传输记录在 `fetch.log`，其中有
`deepen 1`、目标 tag object、服务端 `shallow 68d75f...` 与 `packfile` 记录。

## 可复核工件

全部新工件位于：

```
/home/tanner/.cache/pve-zram-evidence/source-recovery-ubuntu-7.0.0-31.31/
```

其中：

* `repo/` 是精确 commit 的浅层 Git 源码库；其 tag 展开值和 `git cat-file -t` 结果在
  `identity.txt`。
* `audit.txt` 保存精确源码 Kconfig、代码引用和 zram 源文件清单。
* `fsck-full.txt` 显示 `git fsck --full` 退出码为 0。浅层边界会使该 commit 显示为
  `dangling`，这不是对象缺失或校验失败。
* `archive-completeness.txt` 记录在 `GIT_NO_LAZY_FETCH=1` 下对精确 commit 执行
  `git archive --format=tar >/dev/null` 的退出码为 0，证明整个树的 blob 可在本地读取，
  未从网络补取。
* `sha256sums.txt` 固定 pack 与上述审计文件的 SHA-256；pack SHA-256 为
  `a43399edec7f9f8aca6663455466fa115b24da06bfaf1274b82e0c583e9cec2d`。

PVE 包、签名索引、`SOURCE` 文件和 headers 配置的身份链见
`/home/tanner/.cache/pve-zram-evidence/packages/`，以及
`plans/zram-multicomp-evidence.md`。该报告不以相邻版本或不同 PVE tag 代替目标版本。

## 模块范围与最终 PVE 补丁栈审查

对精确 Ubuntu commit 的所有非文档 `CONFIG_ZRAM_MULTI_COMP` 条件引用，只有
`drivers/block/zram/zram_drv.c` 的六处和 `drivers/block/zram/zram_drv.h` 的一处；另外
`debian.master/config/annotations` 将 amd64 及所有 Ubuntu 目标架构策略设为 `n`。两个
LoongArch defconfig 将其设为 `y`，但不属于 PVE amd64 的构建输入。

Kconfig 中该选项仅 `depends on ZRAM`，没有 `select`；`ZRAM_TRACK_ENTRY_ACTIME` 也不是
它的 Kconfig 依赖，只是 idle 重压缩的功能前提。`ZRAM` 本身依赖 `BLOCK && SYSFS && MMU`
并选择 `ZSMALLOC`。`drivers/block/zram/Makefile` 固定编入 `zcomp.o zram_drv.o`，只按各
`CONFIG_ZRAM_BACKEND_*` 添加 backend 对象；没有为 MULTI_COMP 单列 object。换言之，该
选项仅改变现有 `zram_drv.o` 的预处理结构。

源码中的受影响结构均为模块内部范围：它把 `ZRAM_MAX_COMPS` 从 1 改为 4，继而影响
`struct zram` 的 `comps[]`/`params[]` 容量；在 `zram_drv.c` 中增加重压缩扫描与执行代码，
并注册 `recomp_algorithm`（读写）及 `recompress`（只写）两个 sysfs 属性。关闭选项时，
这些函数、属性、属性数组项以及多压缩常量均被同一预处理条件排除，保留单一主压缩器。
这支持“宏影响限于 zram 模块”的源码结论，但不替代构建、ABI 或运行验证。

还审查了精确 PVE 提交 `42c567d...` 与其实际构建输入。该提交本身只是版本递增，只改动
`Makefile` 和 `debian/changelog`；其子模块仍精确指向 `68d75f...`。PVE `Makefile` 的构建
顺序是先从 Ubuntu annotations 导出初始 `.config`、将 390 个 `patches/kernel/*.patch`
应用于子模块源码，随后在实际构建前由 `debian/rules` 应用 PVE config opts 并运行
`olddefconfig`。精确 PVE 树（包括 `debian/`、`Makefile` 和全部 390 个补丁）中没有 `zram`
或 `ZRAM_MULTI_COMP` 命中，且 config opts 没有改变此项。所以现有审计没有发现 PVE 补丁栈
改变 zram 源码、该 Kconfig 选项或其模块局部条件结构；最终发布 headers 的
`# CONFIG_ZRAM_MULTI_COMP is not set` 也与此一致。

上述完整输出保存为 `final-patch-stack-and-macro-audit.txt` 与
`final-macro-scope.txt`，校验值在 `final-g0-audit-sha256sums.txt`。未来若目标 PVE commit、
gitlink、patches/kernel 或 config opts 变化，必须重新对最终组合的源码与配置执行同一审查，
不能把本结论外推到新的补丁栈。

## 范围与剩余限制

已经没有获取精确 G0 源码的阻碍。此证据只回答源码功能和已发布配置是否包含
`CONFIG_ZRAM_MULTI_COMP`；它不验证某台机器实际加载的模块、运行时 sysfs 状态或重编译后
的 ABI/支持性。
