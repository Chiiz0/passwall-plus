# PassWall Plus

PassWall Plus 是基于 [Openwrt-Passwall/openwrt-passwall](https://github.com/Openwrt-Passwall/openwrt-passwall) 的增强分支，重点解决局域网设备身份绑定、按设备选择出口、明确拒绝 IPv6，以及全局和单设备 OpenVPN 全流量转发。

当前源码版本：`26.10.22-r3`

本轮同步上游至 `4b74bdd7`（2026-10-24），吸收节点列表排序与筛选、DNS/订阅修复和下载 SHA-256 校验，同时保留 Plus 的设备绑定与 OpenVPN 功能。专属固件继续使用 OpenWrt `25.12.5`，代理核心更新为 Xray `26.10.21`、Sing-box `1.14.4`。

> 仓库名称为 `passwall-plus`。为兼容现有 OpenWrt 软件包、LuCI 路径、UCI 配置和升级流程，内部包名继续使用 `luci-app-passwall`，配置仍位于 `/etc/config/passwall`。

## 专属 OpenWrt 固件

仓库现在包含基于官方 OpenWrt `25.12.5` 的可复现 x86/64 固件构建。它固定官方 SDK、ImageBuilder、全部 OpenWrt feed 及 PassWall 依赖 feed，不使用 Kwrt 的滚动软件源、fullcone 改动或自定义 miniupnp 包。

成品固件直接包含 PassWall Plus、OpenVPN、Xray、Sing-box、LuCI 简体中文和 VMware/QEMU 驱动，并生成 BIOS/UEFI、ext4/squashfs 及 VMware VMDK 镜像。默认双网卡定义为：

| 接口 | 用途 | 默认配置 |
| --- | --- | --- |
| `eth0` | LAN | `10.0.0.1/24`，提供 DHCP |
| `eth1` | WAN | DHCP，从任意可用的 IPv4 DHCP 上联获取地址、网关和 DNS |

IPv6 会从内核 sysctl、WAN/LAN 接口、RA/DHCPv6 和 PassWall 同时关闭，LAN 防火墙仍保留一条显式 IPv6 `REJECT` 规则。构建和 QEMU 验证方法见 [openwrt/README.md](openwrt/README.md)。固件不内置订阅、`.ovpn`、私钥或默认密码。

可直接从 [GitHub Releases](https://github.com/Chiiz0/passwall-plus/releases) 下载固件。普通 BIOS 的 VMware 虚拟机选择 `generic-ext4-combined.vmdk`，UEFI 虚拟机选择 `generic-ext4-combined-efi.vmdk`；其他虚拟化平台或物理 x86/64 设备可使用对应的压缩 `.img.gz`。每个 Release 同时提供 `SHA256SUMS`。

Release 还提供与该固件匹配的 LuCI 主程序和简体中文 APK。Plus 的 LuCI 在线更新只使用本仓库的发布包，并按 APK 中的应用版本判断更新；Xray、Sing-box 等独立组件继续使用各自上游。旧版 OpenWrt 的 IPK 需在对应 SDK 中自行编译。

当前固件已用双 e1000 网卡实际启动验证：WAN DHCP、LuCI、OpenVPN/Xray/Sing-box、IPv6 禁用、`fw4 check` 和 `fw4 reload` 均通过，内核日志没有 nftables 段错误。由此绕开 Kwrt 的固件基线问题，而不是在 PassWall 中掩盖 `libnftables` 崩溃。

## 核心能力

| 能力 | 行为 |
| --- | --- |
| DHCP 静态租约 | 为启用绑定的访问控制条目自动维护永久 IPv4 租约 |
| IP/MAC 强绑定 | 同时阻止绑定 MAC 使用其他 IPv4，以及其他 MAC 冒用绑定 IPv4 |
| 单设备出口策略 | 不同设备可分别选择直连、全局配置、普通代理节点或 OpenVPN 节点 |
| IPv6 明确拒绝 | 默认拒绝来自 `lan` 区域的 IPv6，不允许通过 IPv6 绕过设备策略 |
| 全局 OpenVPN | 可将全部 LAN 客户端和路由器本机的 TCP、UDP、ICMP、DNS 接入同一 TUN 隧道 |
| 单设备 OpenVPN | 可为指定设备选择独立 OpenVPN 节点和策略路由表，不影响其他设备 |
| OpenVPN 防回落 | 隧道未建立或意外断开时保持阻断，不会静默切回 WAN |
| OpenVPN 前置代理 | 可通过普通 Xray 或 Sing-box 节点提供的本机 SOCKS 连接 VPN 服务端 |
| LAN 访问控制 | 可按设备决定使用 OpenVPN 时是否保留本地 LAN 访问 |

设备策略由同一条访问控制配置驱动，DHCP 租约、身份校验和出站策略会一起生效或清理。发现重复 IP、重复 MAC 或 DHCP 冲突时，对应设备不会被错误放行。

## 流量策略

| 设备选择 | IPv4 出口 | 出口不可用时 | IPv6 |
| --- | --- | --- | --- |
| 直连 | OpenWrt WAN | 遵循系统路由 | 拒绝 |
| 全局配置 | PassWall 全局节点，包括可选 OpenVPN | OpenVPN 模式阻断，否则遵循原有全局策略 | 拒绝 |
| 独立代理节点 | 设备专属 Xray/Sing-box 等节点 | 遵循节点策略 | 拒绝 |
| OpenVPN 节点 | 设备专属策略路由表和 TUN | 阻断公网，防止回落 | 拒绝 |

每个启用绑定的访问控制条目应只表示一台设备。保存配置后，应让客户端重新获取 DHCP 租约，使其使用绑定的 IPv4 地址。

## OpenVPN 集成

编译时启用 `Include OpenVPN client`，在节点列表中新建 OpenVPN 节点并粘贴完整的 `.ovpn` 客户端配置。OpenVPN 节点既可以选作 PassWall 全局节点，也可以只分配给访问控制中的单台设备。PassWall Plus 会为每个实际使用的 OpenVPN 节点创建独立的：

- TUN 设备和 IPv4 策略路由表；
- 源地址路由规则、出口 NAT 和防火墙转发规则；
- 不可达默认路由和防火墙防回落规则；
- 强制通过隧道访问的 IPv4 DNS 规则；
- 可选的 Xray/Sing-box SOCKS 前置进程。

全局 OpenVPN 固定使用 `pswov0` 和策略路由表 `20000`；仅由设备使用的 OpenVPN 节点从 `pswov1` 和表 `20001` 开始分配。同一个节点同时被全局配置和设备条目引用时会复用同一进程和 TUN，不会重复拨号。

全局模式可分别使用 PassWall 原有的“代理局域网设备”和“代理本机”开关控制 LAN 与路由器本机。选择“使用全局配置”的访问控制条目继承全局 OpenVPN；选择直连、独立普通代理或独立 OpenVPN 的条目会按自己的策略优先于全局规则。每台绑定设备仍使用自己的静态租约、IP/MAC 校验和访问控制条目。

### IPv4 与配置约束

- VPN 服务端连接强制使用 IPv4。
- 配置中的 IPv6 远端、IPv6 TUN 地址、IPv6 路由和 DNS6 推送会被移除。
- 前置代理模式会把 VPN 服务端域名预解析为 IPv4；本地 DNS 不可用时会使用 IPv4 DoH 查询 A 记录。
- 前置代理要求 VPN 服务端支持 TCP，OpenVPN 会使用 `tcp4-client` 连接本机 SOCKS。
- 导入配置中的脚本钩子、管理端口、守护进程、外部配置包含、自定义系统路由和已有代理指令会被移除。
- 证书认证可直接使用内联 `<ca>`、`<cert>`、`<key>` 和 `<tls-crypt>` 等内容。
- 用户名/密码认证应填写节点页面中的对应字段；配置引用的外部认证文件不会直接使用。

OpenVPN 配置可能包含私钥和账号信息。不要把真实配置提交到 Git，也不要公开包含 `/etc/config/passwall` 的未加密备份。

## 编译

### OpenWrt feeds

在 `feeds.conf.default` 顶部加入：

```text
src-git passwall_packages https://github.com/Openwrt-Passwall/openwrt-passwall-packages.git;main
src-git passwall_plus https://github.com/Chiiz0/passwall-plus.git;main
```

更新并安装 feeds：

```sh
./scripts/feeds update passwall_packages passwall_plus
./scripts/feeds install -a -p passwall_packages
./scripts/feeds install -f -p passwall_plus luci-app-passwall
```

然后在 `make menuconfig` 中选择：

```text
LuCI -> Applications -> luci-app-passwall
```

根据需要启用：

- `Include OpenVPN client`
- `Include Xray`
- `Include Sing-Box`
- 与目标固件匹配的 nftables 或 iptables 透明代理后端

OpenVPN 选项会选择 `openvpn-openssl` 和 `kmod-tun`。前置代理至少需要启用 Xray 或 Sing-box 其中之一。

### 手动加入源码树

在已经安装 OpenWrt feeds 的源码树中执行：

```sh
rm -rf package/passwall-plus
git clone https://github.com/Chiiz0/passwall-plus.git package/passwall-plus
make menuconfig
```

核心代理程序仍建议使用官方依赖仓库：

```sh
git clone https://github.com/Openwrt-Passwall/openwrt-passwall-packages.git package/passwall-packages
```

## 配置流程

1. 在“节点列表”中添加或订阅普通代理节点。
2. 如需 OpenVPN，在“节点列表”中新建 OpenVPN 节点并导入客户端配置。
3. 如需前置跳板，在 OpenVPN 节点中选择普通 Xray 或 Sing-box 节点。
4. 全局使用时，在“基本设置”的主节点中直接选择 OpenVPN，并设置是否保留本地 LAN 访问。
5. 按设备使用时，打开“访问控制”，为设备启用 IP/MAC 绑定并填写固定 IPv4、MAC 和可选主机名。
6. 为该设备选择直连、全局配置、普通代理节点或 OpenVPN 节点。
7. 保存并应用，然后让客户端重新获取 DHCP 地址。

全局 OpenVPN 的“允许本地 LAN 访问”位于基本设置；独立 OpenVPN 设备也可以在访问控制条目中单独设置。关闭后，除 DHCP 外，受管设备只能通过已建立的 VPN 隧道通信。

## 验证建议

应用配置后至少检查以下内容：

```sh
# 静态租约
uci show dhcp | grep passwall_managed

# IP/MAC 绑定和 IPv6 拒绝规则
nft list table inet passwall

# OpenVPN 进程、TUN 和策略路由
pgrep -af openvpn
ip -4 addr show
ip -4 rule show
ip -4 route show table all
```

应分别验证正确 IP/MAC、伪造 IP、伪造 MAC、VPN 正常和 VPN 断线五种状态。断线测试中，绑定设备应无法访问公网，但在启用“允许本地 LAN 访问”时仍能访问 LAN。

## 已完成的真机测试

以下场景已在 x86_64 OpenWrt/Kwrt 虚拟机中完成实际流量验证，而不只是检查配置文件：

| 测试项 | 结果 |
| --- | --- |
| DHCP 永久静态租约生成与清理 | 通过 |
| 正确 IP/MAC 正常转发 | 通过 |
| 正确 MAC 伪造 IPv4 | 丢弃，nft 计数器命中 |
| 正确 IPv4 伪造 MAC | 丢弃，nft 计数器命中 |
| IPv6 明确拒绝 | 通过 |
| OpenVPN 证书握手和 TUN 地址获取 | 通过 |
| 单设备 TCP、UDP、ICMP、DNS 全隧道 | 通过 |
| 隧道断开防回落与 LAN 保留 | 通过 |
| OpenVPN 经 Sing-box/VMess 前置 | 通过 |
| OpenVPN 经 Xray/VMess 前置 | 通过 |
| 全局 LAN 与路由器本机 TCP、ICMP、DNS、NAT | 通过 |
| 全局 OpenVPN 断线防回落与 LAN 隔离 | 通过 |
| 全局 OpenVPN 经 Sing-box/VMess 前置 | 通过 |
| 全局 OpenVPN 经 Xray/VMess 前置 | 通过 |
| 全局 OpenVPN 与直连、继承、独立设备策略并存 | 通过 |

测试环境包含 Linux `6.12.103`、OpenVPN `2.7.6` 和 Xray `26.7.28`。

## 固件兼容性

- firewall4 环境会优先识别真实 `fw4` 后端，不会被某些固件提供的 `/sbin/fw3 -> fw4` 兼容链接误导。
- 部分第三方 Kwrt 快照中的 `nft 1.1.6` 可能在执行 `fw4 reload` 时段错误。该问题在停止 PassWall 并删除 `inet passwall` 表后仍可复现，属于固件的 nftables/firewall4 基线问题；建议更新固件或相关组件。
- 本仓库的专属固件使用 OpenWrt 25.12.5 官方 firewall4/nftables 构建组合，QEMU 实测 `fw4 reload` 正常且 `dmesg` 无崩溃，可直接作为该 Kwrt 问题的替代方案。
- IPv6 拒绝区域默认是 `lan`，多 LAN 或自定义防火墙区域应在 PassWall 全局配置中明确加入。

## 上游与许可证

本项目保留 PassWall 的包结构和上游兼容性。通用代理能力、节点格式和依赖包继续来自：

- [Openwrt-Passwall/openwrt-passwall](https://github.com/Openwrt-Passwall/openwrt-passwall)
- [Openwrt-Passwall/openwrt-passwall-packages](https://github.com/Openwrt-Passwall/openwrt-passwall-packages)

代码按照 [GPL-3.0](LICENSE) 发布。

## Xray 证书验证提示

自 2026 年 6 月 1 日起，Xray Core 内部定时器会弃用 `allowInsecure`。使用自签证书的节点需要提供 `pinnedPeerCertSha256`（订阅参数 `pcs`），否则连接可能失败。无法取得 `pcs` 时，可以改用 Sing-box Core 或更换使用受信任证书的节点。
