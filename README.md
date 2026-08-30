# PassWall Plus

PassWall Plus 是基于 [Openwrt-Passwall/openwrt-passwall](https://github.com/Openwrt-Passwall/openwrt-passwall) 的增强分支，重点解决局域网设备身份绑定、按设备选择出口、明确拒绝 IPv6，以及单设备 OpenVPN 全流量转发。

当前源码版本：`26.8.26-r5`

> 仓库名称为 `passwall-plus`。为兼容现有 OpenWrt 软件包、LuCI 路径、UCI 配置和升级流程，内部包名继续使用 `luci-app-passwall`，配置仍位于 `/etc/config/passwall`。

## 核心能力

| 能力 | 行为 |
| --- | --- |
| DHCP 静态租约 | 为启用绑定的访问控制条目自动维护永久 IPv4 租约 |
| IP/MAC 强绑定 | 同时阻止绑定 MAC 使用其他 IPv4，以及其他 MAC 冒用绑定 IPv4 |
| 单设备出口策略 | 不同设备可分别选择直连、全局配置、普通代理节点或 OpenVPN 节点 |
| IPv6 明确拒绝 | 默认拒绝来自 `lan` 区域的 IPv6，不允许通过 IPv6 绕过设备策略 |
| OpenVPN 全流量 | 将指定设备的 TCP、UDP、ICMP 和 DNS 全部送入独立 TUN 隧道 |
| OpenVPN 防回落 | 隧道未建立或意外断开时保持阻断，不会静默切回 WAN |
| OpenVPN 前置代理 | 可通过普通 Xray 或 Sing-box 节点提供的本机 SOCKS 连接 VPN 服务端 |
| LAN 访问控制 | 可按设备决定使用 OpenVPN 时是否保留本地 LAN 访问 |

设备策略由同一条访问控制配置驱动，DHCP 租约、身份校验和出站策略会一起生效或清理。发现重复 IP、重复 MAC 或 DHCP 冲突时，对应设备不会被错误放行。

## 流量策略

| 设备选择 | IPv4 出口 | 出口不可用时 | IPv6 |
| --- | --- | --- | --- |
| 直连 | OpenWrt WAN | 遵循系统路由 | 拒绝 |
| 全局配置 | PassWall 全局节点 | 遵循全局策略 | 拒绝 |
| 独立代理节点 | 设备专属 Xray/Sing-box 等节点 | 遵循节点策略 | 拒绝 |
| OpenVPN 节点 | 设备专属策略路由表和 TUN | 阻断公网，防止回落 | 拒绝 |

每个启用绑定的访问控制条目应只表示一台设备。保存配置后，应让客户端重新获取 DHCP 租约，使其使用绑定的 IPv4 地址。

## OpenVPN 集成

编译时启用 `Include OpenVPN client`，在节点列表中新建 OpenVPN 节点并粘贴完整的 `.ovpn` 客户端配置。PassWall Plus 会为每个实际使用的 OpenVPN 节点创建独立的：

- TUN 设备和 IPv4 策略路由表；
- 源地址路由规则、出口 NAT 和防火墙转发规则；
- 不可达默认路由和防火墙防回落规则；
- 强制通过隧道访问的 IPv4 DNS 规则；
- 可选的 Xray/Sing-box SOCKS 前置进程。

同一个 OpenVPN 节点可以分配给多台已绑定设备。每台设备仍使用自己的静态租约、IP/MAC 校验和访问控制条目。

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
4. 打开“访问控制”，为设备启用 IP/MAC 绑定并填写固定 IPv4、MAC 和可选主机名。
5. 为该设备选择直连、全局配置、普通代理节点或 OpenVPN 节点。
6. 保存并应用，然后让客户端重新获取 DHCP 地址。

使用 OpenVPN 时，可以为访问控制条目单独设置“允许本地 LAN 访问”。关闭后，除 DHCP 外，该设备只能通过已建立的 VPN 隧道通信。

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

测试环境包含 Linux `6.12.103`、OpenVPN `2.7.6` 和 Xray `26.7.28`。

## 固件兼容性

- firewall4 环境会优先识别真实 `fw4` 后端，不会被某些固件提供的 `/sbin/fw3 -> fw4` 兼容链接误导。
- 部分第三方 Kwrt 快照中的 `nft 1.1.6` 可能在执行 `fw4 reload` 时段错误。该问题在停止 PassWall 并删除 `inet passwall` 表后仍可复现，属于固件的 nftables/firewall4 基线问题；建议更新固件或相关组件。
- IPv6 拒绝区域默认是 `lan`，多 LAN 或自定义防火墙区域应在 PassWall 全局配置中明确加入。

## 上游与许可证

本项目保留 PassWall 的包结构和上游兼容性。通用代理能力、节点格式和依赖包继续来自：

- [Openwrt-Passwall/openwrt-passwall](https://github.com/Openwrt-Passwall/openwrt-passwall)
- [Openwrt-Passwall/openwrt-passwall-packages](https://github.com/Openwrt-Passwall/openwrt-passwall-packages)

代码按照 [GPL-3.0](LICENSE) 发布。

## Xray 证书验证提示

自 2026 年 6 月 1 日起，Xray Core 内部定时器会弃用 `allowInsecure`。使用自签证书的节点需要提供 `pinnedPeerCertSha256`（订阅参数 `pcs`），否则连接可能失败。无法取得 `pcs` 时，可以改用 Sing-box Core 或更换使用受信任证书的节点。
