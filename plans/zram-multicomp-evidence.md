# ZRAM multi-comp：精确 PVE 7.0.14-16-pve 包与来源证据

采集时间：2026-09-06；仅下载到
`/home/tanner/.cache/pve-zram-evidence/packages/`，未修改主机软件包、内核、服务或
swap。目标是 **7.0.14-16-pve**，没有使用邻近版本替代。

## G1：精确包身份（已取得 pve-test 样本）

官方索引 URL：

```
http://download.proxmox.com/debian/pve/dists/trixie/InRelease
http://download.proxmox.com/debian/pve/dists/trixie/pve-test/binary-amd64/Packages.gz
```

`InRelease` 的 OpenPGP 签名已用随 Proxmox 镜像提供的
`proxmox-archive-keyring.gpg` 验证：

```
gpgv: Good signature from "Proxmox Trixie Release Key <proxmox-release@proxmox.com>"
key fingerprint: 24B3 0F06 ECC1 836A 4E5E FECB A7BC D142 0BFE 778E
```

该已签名 Release 中的 `pve-test/binary-amd64/Packages.gz` SHA-256 是
`e24fd876688e1ab1c39c49e8115bd20eb7f59c2f0f5c52d086744271a4fa6ed1`；下载文件实测
一致。完整签名索引 SHA-256 是
`d4b3af77f59af2eb2ac9d8afcefced3868212a8727b887208462533c1219ac41`。

精确条目（两者 `Source: proxmox-kernel-7.0`）如下：

| 包 | 版本 | 文件 | SHA-256 |
| --- | --- | --- | --- |
| `proxmox-kernel-7.0.14-16-pve` | `7.0.14-16` | `dists/trixie/pve-test/binary-amd64/proxmox-kernel-7.0.14-16-pve_7.0.14-16_amd64.deb` | `71b3dc93d44390b8b597f04a97106483c46f2d1ee26ce4754a207e072b400f01` |
| `proxmox-headers-7.0.14-16-pve` | `7.0.14-16` | `dists/trixie/pve-test/binary-amd64/proxmox-headers-7.0.14-16-pve_7.0.14-16_amd64.deb` | `21e15b544688249229f9ad7830625e9e5f31554f13c00c6d1a48e381b19c49cd` |

两个 `.deb` 均已由 APT 下载并以索引中的 SHA-256 复核。它们各自的
`/usr/share/doc/<package>/SOURCE` 内容一致：

```
git clone git://git.proxmox.com/git/pve-kernel.git
git checkout 42c567d939ee67d2c610b55dca4569a6e6d8e4ea
```

这个 PVE 提交的 gitlink 恰为
`68d75f0820869e33326712a9547550961795eaaf`，因此包、`SOURCE`、工作树目标和
Ubuntu 子模块目标形成了精确映射。headers 包还包含同一 ABI 的 `.config`、
`Module.symvers` 与 `drivers/block/zram/{Kconfig,Makefile}`。

信任范围：签名验证使用的 keyring 来自已存在的 `docker.io/dockurr/proxmox:9.2.10`
镜像，keyring 文件 SHA-256 为
`136673be77aba35dcce385b28737689ad64fd785a797e57897589aed08db6e45`。因此可证明该
索引由此 keyring 的 Trixie Proxmox 发布键签署；本轮没有另从 Proxmox 的带外渠道
重新固定该公钥。直接 `curl` 的 HTTPS 端点在此环境出现证书名称不匹配/401，不能视为
信任验证；上述 APT/GPG 路径才是本记录采用的验证方式。

`pve-no-subscription` 的当期稳定索引最高为 `7.0.14-15`；精确 `-16` 在 `pve-test`
可用。这是发布通道事实，不代表任何生产支持结论。

## G0：精确 Ubuntu 子模块源码（仍有获取缺口）

官方 Git URL 是 `https://git.proxmox.com/git/mirror_ubuntu-kernels.git`。对精确
gitlink 的 fetch 被服务器接受，但服务器忽略了浅/过滤请求并发送约 11,452,468
对象的完整 pack。已配置 2 GiB 阈值；因五秒轮询与进行中的 pack 写入，观察到工作目录
约 2.35 GB 时才主动停止（约 394 秒）。结果为 exit code 143，尚未得到对象
（`git cat-file -t 68d75f...` 失败）。这次超出目标阈值的部分不应在后续重试中重复；
应改用能在传输层限制字节数的方式。日志保留在：

```
/home/tanner/.cache/pve-zram-evidence/fetch-68d75f.log
/home/tanner/.cache/pve-zram-evidence/fetch-68d75f.result
```

这说明先前较早中止不能证明对象不存在，也不构成完整源码可用证据。不得把镜像中不同的
`Proxmox-7.0.14-1` 标签（`176218573332c6033483e6a89bc7a6695f645290`）当成替代品。

虽然 headers 样本显示 `CONFIG_ZRAM_MULTI_COMP` 未设置，且其 Kconfig 含该配置项，
这只是已发布目标 headers 的事实；在未获得完整精确源码前，本记录不据此作模块重编译、
ABI 或运行支持结论。

## 可复核证据文件

`/home/tanner/.cache/pve-zram-evidence/packages/` 保存签名索引、GPG 验证日志、精确
Packages stanzas、两个 `.deb`、各包 `SOURCE` 抽取物与 SHA-256。关键文件为：

```
trixie-InRelease
trixie-InRelease.gpgv.log
trixie-pve-test-Packages.gz
exact-pve-test-index-stanzas.txt
exact-package-stanzas.txt
proxmox-*-7.0.14-16-pve_7.0.14-16_amd64.deb
proxmox-*-7.0.14-16-pve_7.0.14-16_amd64.SOURCE
exact-headers-zram-and-config.txt
```
