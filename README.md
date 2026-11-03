# PassWall Plus

PassWall Plus 是基于 [Openwrt-Passwall/openwrt-passwall](https://github.com/Openwrt-Passwall/openwrt-passwall) 的增强分支，重点解决局域网设备身份绑定、按设备选择出口、明确拒绝 IPv6，以及全局和单设备 OpenVPN 全流量转发。

当前源码版本：`26.10.29-r3`，云控插件：`0.2.0-r2`

本轮同步上游至 `cde9833e`（PassWall `26.10.29`），包含核心更新校验、节点筛选界面、DNS/规则与 Xray 配置修复。专属固件 `25.12.6-r3` 使用 Xray `26.10.31`、Go `1.27.3` 和 Sing-box `1.14.4`，并默认禁用内核 MPTCP，以缓解近期 IPv4 MPTCP 监听漏洞。固件基线同步到 OpenWrt `25.12.6` / Linux `6.12.112`，包含新版 Web/TLS 等组件的安全修复；MPTCP 继续禁用作为额外缓解措施。

> 仓库名称为 `passwall-plus`。为兼容现有 OpenWrt 软件包、LuCI 路径、UCI 配置和升级流程，内部包名继续使用 `luci-app-passwall`，配置仍位于 `/etc/config/passwall`。

## 专属 OpenWrt 固件

仓库现在包含基于官方 OpenWrt `25.12.6` 的可复现 x86/64 固件构建。它固定官方 SDK、ImageBuilder、全部 OpenWrt feed 及 PassWall 依赖 feed，不使用 Kwrt 的滚动软件源、fullcone 改动或自定义 miniupnp 包。

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

### passwall-EzCNet 云控

新增独立软件包 `luci-app-passwall-ezcnet`，专属固件构建会自动包含。
在 LuCI“服务 → passwall-EzCNet”中填写 `https://passwall.ezcnet.com`
和平台生成的设备 Key，启用后可查看状态，管理订阅、导入 URI/Base64/Clash/OpenVPN
节点，预览后应用，搜索、测试、切换和删除节点，并修改主代理开关、TCP/UDP
策略、本机/LAN 代理以及已有 ACL 的启用开关。
插件默认关闭，不预置 Key，不开放额外管理端口。

配置下发包含版本冲突检查、稳定节点 ID、引用保护、异步回执和失联回滚。
普通心跳不上传订阅 URL、节点密钥或完整配置；用户提交的导入内容在云端临时加密排队，完成后清除。云控服务端与部署说明位于同级独立项目
`../passwall-EzCNet/`。从专属固件 `25.12.5-r5` 起默认打包此插件；更早的
镜像需升级固件或安装匹配版本的软件包。详细说明见
[云控插件说明](luci-app-passwall-ezcnet/README.md)。

### 代理与设备策略

| 能力 | 行为 |
| --- | --- |
| DHCP 静态租约 | 为启用绑定的访问控制条目自动维护永久 IPv4 租约 |
| IP/MAC 强绑定 | 同时阻止绑定 MAC 使用其他 IPv4，以及其他 MAC 冒用绑定 IPv4 |
| 单设备出口策略 | 不同设备可分别选择直连、全局配置、普通代理节点或 OpenVPN 节点 |
| IPv6 明确拒绝 | 默认拒绝来自 `lan` 区域的 IPv6，不允许通过 IPv6 绕过设备策略 |
| 全局 OpenVPN | 可将全部 LAN 客户端和路由器本机的 TCP、UDP、ICMP、DNS 接入同一 TUN 隧道 |
| 单设备 OpenVPN | 可为指定设备选择独立 OpenVPN 节点和策略路由表，不影响其他设备 |
| 节点切换保护 | 启动、重启、切换节点和在线替换核心时先阻断网络，进程、规则和连通性验证后恢复；失败时自动回退或受保护重试 |
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

## 节点切换网络保护

基本设置 → 代理中的“节点切换网络保护”默认开启，已有配置缺少该选项时也默认生效。切换前先安装独立的防火墙保护，随后停止旧节点、启动新节点；确认核心进程、代理/DNS 监听和防火墙规则就绪，并通过实际 SOCKS 或绑定 VPN 设备完成 HTTPS 连通性验证后，才解除保护。LuCI、订阅更新、云控重启和在线核心替换都使用这一流程。

切换期间所有设备（包括直连 ACL）的转发、客户端 DNS 和普通路由器出网会短暂停顿。管理连接应答、DHCP/IPv6 邻居发现、代理启动连接及专用 `ntp` 账户的 UDP/123 校时仍可使用。节点和 VPN 检查域名仅由专用启动进程解析，不放行普通应用的直连 DNS。保护规则独立于普通代理规则，并处理可能绕过转发链的流量卸载缓存。

每次验证成功后，保存一份最近可用配置。新节点、配置或核心失败时，自动恢复该配置；核心在线更新还会恢复旧二进制。没有可用备份或回退仍失败时，独立的 procd 监控保持保护，按 5～30 秒退避继续恢复；核心启动较慢时会持续检查，不因首次检查失败永久断网。监控也检查运行中的进程与监听端口，发现异常后进入受保护恢复。连通性等待窗口为 30 秒，停止、启动和回退还需要额外时间；所有出口都失效时不会通过超时直接放行 WAN。

“切换连通性检查网址”可设置多个返回 200 或 204 的 HTTPS 地址，任意一个成功即可；留空使用节点测试网址和 Gstatic。检查验证 TLS 证书，各个实际使用的普通代理和 VPN 都必须通过。复杂分流或内网 VPN 应选择其策略允许访问的检查地址；检查成功只证明该路径可用，不代表每个分流分支或所有网站都可达。页面显示恢复结果。成功配置和失败候选保存在仅 root 可读的 `/etc/passwall/.switch/`，其中可能包含节点凭据，不应公开。

新切换或主动停止会取消旧任务，回退前检查请求编号、配置摘要和订阅更新锁，避免旧任务覆盖已变更的配置。主动点击停止或执行 `/etc/init.d/passwall stop` 表示允许恢复系统网络；停止也会清理丢失状态标记的残留保护规则。规则查询或删除失败时保留恢复状态并继续重试。保护安装失败时，若旧代理已验证可用，则取消切换并恢复旧配置及网络。

nftables/firewall4 使用标准 fw4 流量卸载表；遇到其他自定义卸载表会取消切换。fw3 开启流量卸载时需要安装 `conntrack`。专属固件在 nftables/IPv4 下进行真实包测试，并默认关闭 IPv6；fw3 和其他硬件卸载平台仍需在对应设备验证。

保护不会改变正常运行时的分流或直连策略，也不替代 OpenVPN 已有的持续断线防回落。

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
- 本仓库的专属固件使用 OpenWrt 25.12.6 官方 firewall4/nftables 构建组合，QEMU 实测 `fw4 reload` 正常且 `dmesg` 无崩溃，可直接作为该 Kwrt 问题的替代方案。
- IPv6 拒绝区域默认是 `lan`，多 LAN 或自定义防火墙区域应在 PassWall 全局配置中明确加入。

## 上游与许可证

本项目保留 PassWall 的包结构和上游兼容性。通用代理能力、节点格式和依赖包继续来自：

- [Openwrt-Passwall/openwrt-passwall](https://github.com/Openwrt-Passwall/openwrt-passwall)
- [Openwrt-Passwall/openwrt-passwall-packages](https://github.com/Openwrt-Passwall/openwrt-passwall-packages)

代码按照 [GPL-3.0](LICENSE) 发布。

## Xray 证书验证提示

自 2026 年 6 月 1 日起，Xray Core 内部定时器会弃用 `allowInsecure`。使用自签证书的节点需要提供 `pinnedPeerCertSha256`（订阅参数 `pcs`），否则连接可能失败。无法取得 `pcs` 时，可以改用 Sing-box Core 或更换使用受信任证书的节点。
