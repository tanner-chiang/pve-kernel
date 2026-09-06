# 隔离 PVE 测试环境

本目录只记录 ZRAM 多压缩器工作的 PVE 测试入口；它不会操作宿主的
`/dev/zram0`、加载模块、修改启动项或使用物理磁盘。

## Dockur 的用途和边界

文档来源：<https://github.com/dockur/proxmox>（`readme.md`、`compose.yml`、
`Dockerfile`，于 2026-09-06 核验）。Dockur 官方运行要求为 Linux Docker/Podman
加 KVM、至少 2 GiB 可用内存和 32 GiB 可用磁盘。官方 compose 使用
`privileged: true`，并持久化 `/var/lib/vz` 与 `/var/lib/pve-cluster`。

本机已拉取固定镜像 `docker.io/dockurr/proxmox:9.2.10`
（image ID `f9f412c7d63e04cc3a4d615ca5bf4b359dc45194a5e06345a498944d159e1e39`）。
它只可作为 PVE 用户态和 Debian 包工具的来源：其官方 Dockerfile 明确删除
`/usr/lib/modules` 和 `/boot`，容器中的 `uname -r` 是 Fedora 宿主的内核。
因此它**不能**用于加载、卸载或重启 PVE kernel，也不能执行任何宿主 swap/ZRAM
测试。本次没有以 privileged/systemd 方式启动该容器。

## 真实 PVE kernel 的目标

`6.17.13-21-pve` 仅是独立 VM smoke 示例，不能作为本工作树目标的阶段 1
证据。当前精确证据目标为官方 `pve-test` Trixie 的 `7.0.14-16-pve`；二者不得混同。
下载前以 Proxmox Trixie Release Key
`24B3 0F06 ECC1 836A 4E5E FECB A7BC D142 0BFE 778E` 验证 `InRelease`，再核对
Packages 索引中的 SHA-256：

| 包 | 文件 | SHA-256 |
| --- | --- | --- |
| `proxmox-kernel-6.17.13-21-pve` | `proxmox-kernel-6.17.13-21-pve_6.17.13-21_amd64.deb` | `fd6d2d9f45f44cba911372fa6348578f7dd2867ea7c4513c7bb38c92807b55c1` |
| `proxmox-headers-6.17.13-21-pve` | `proxmox-headers-6.17.13-21-pve_6.17.13-21_amd64.deb` | `f8a5b2d0476b90a211da6bc43bcabe3f7b874aad0839e819867ce96016649107` |

样本存放在任务临时目录 `/tmp/pve-zram-6.17.13-21/`，不纳入 Git。

## 真正 VM 的准备条件

已验证的宿主能力为 QEMU 10.2、KVM、VMX、`/dev/kvm`、`/dev/fuse` 和
`/dev/net/tun`；QMP 的 `-machine accel=kvm:tcg -cpu host` 探测成功。
真实内核验证应使用独立 QEMU VM，建议配置：官方 PVE 9.2-1 ISO（约 1.7 GiB）、
48 GiB sparse qcow2、4 GiB RAM、2 vCPU，以及 QEMU user networking 的
`127.0.0.1` 转发。虚拟磁盘和 ISO 必须都在任务临时目录内；不要使用宿主物理盘。
安装器若要求人工输入，则停止在安装器界面并记录下一步，不能无限等待。
