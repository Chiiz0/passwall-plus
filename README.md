# PassWall Plus

PassWall Plus 是基于 PassWall 的 OpenWrt 路由插件，让同一局域网里的设备使用不同的 IPv4 出口。例如，工作电脑走 OpenVPN，电视直连，其余设备使用全局代理。策略配置在路由器上，客户端无需安装软件。VPN 意外断开时，工作电脑的公网流量会被阻断，避免回落到 WAN。

[下载固件与软件包](https://github.com/Chiiz0/passwall-plus/releases) · [固件构建指南](openwrt/README.md) · [版本说明](openwrt/releases/) · [问题反馈](https://github.com/Chiiz0/passwall-plus/issues/new/choose)

## 选择安装方式

| 使用场景 | 安装方式 |
| --- | --- |
| 在 x86/64 软路由或虚拟机上新部署 | 使用 EzWrt 固件，已集成 PassWall Plus、OpenVPN、Xray、Sing-box 和简体中文 LuCI。见[首次启动](#ezwrt-首次启动)。 |
| 已在使用 EzWrt 专属固件 | 在「服务 → PassWall Plus → 组件更新」升级主插件。手动安装时，从对应 Release 选择与固件匹配的主程序和中文 APK。 |
| 自己编译 OpenWrt，或使用旧版 opkg 固件 | 将 Plus 加入目标源码树或 SDK。发布页的 APK 面向专属 OpenWrt 25.12 固件，旧版 opkg 系统需要为目标版本编译 IPK。见[编译插件](#编译插件)。 |

### EzWrt 首次启动

1. **选择镜像。** VMware 传统 BIOS 选文件名以 `-ext4-combined.vmdk` 结尾的镜像，UEFI 选 `-ext4-combined-efi.vmdk`。其他 x86/64 平台可下载对应启动方式的 `combined*.img.gz` 整盘镜像。
2. **校验并部署。** 将同一 Release 的 `SHA256SUMS` 和原始镜像放在同一目录。在 Linux 上运行 `sha256sum --check --ignore-missing SHA256SUMS`，确认所选文件显示 `OK`。VMDK 可直接挂载为虚拟硬盘，压缩镜像需解压后写入目标磁盘。
3. **连接网口。** 至少准备两张网卡。第一张（`eth0`）连接上游网络，通过 DHCP 获取 IPv4 地址。第二张（`eth1`）接管理电脑，其余 `ethN` 网口也会加入 LAN。从 `25.12.6-r3` 迁移时请先备份网络配置，r4 起 WAN 与 LAN 的顺序已对调。
4. **登录 LuCI。** 让管理电脑自动获取地址，在浏览器打开 `http://10.0.0.1/`。首次登录后先设置 root 密码，再进入「服务 → PassWall Plus」导入自己的节点或 VPN 配置。

## 配置设备出口

「全局出口」决定默认路径，「单设备出口」为特定设备设置例外。设备规则从上到下匹配，第一条命中规则优先于全局设置。启用 IP/MAC 绑定后，Plus 会维护永久 DHCP 租约，并阻止绑定的 MAC 改用其他 IPv4，或其他 MAC 冒用该地址。

| 希望设备如何联网 | LuCI 中的选择 |
| --- | --- |
| 直连 WAN | 在设备策略中选择「不代理」。 |
| 跟随全局设置 | 选择「使用全局配置」，以后调整全局出口时设备随之切换。 |
| 使用指定代理节点 | 在「节点列表」添加节点，或通过「节点订阅」导入，再在设备策略中选择该节点。 |
| 所有 IPv4 公网流量经过 VPN | 启用 IP/MAC 绑定并选择 OpenVPN 节点。TCP、UDP、ICMP 和 DNS 走隧道，可单独设置「允许访问本地 LAN」。 |

### 为全局出口设置主备节点

在「全局出口 → 主要」开启主开关，把首选节点设为「代理节点」，再选择「备用出口」并保存应用。两端可以是两个普通代理节点，也可以是两个 OpenVPN 节点。备用出口默认关闭。

运行中约每 30 秒通过当前出口发起 HTTPS 检查，连续三次失败后尝试备用节点。启动时主节点未通过验证，也会尝试备用节点。使用备用出口期间，Plus 通过独立的本地代理或探测隧道检查主节点，连续三次成功后回切。OpenVPN 主备共用账号时，服务端需要允许两条隧道同时在线。切换沿用网络保护设置，已有连接可能需要重连。「总览面板 → 全局运行记录」显示实际出口，跟随全局的设备会一起切换。

### 让一台工作电脑走 OpenVPN

1. 在「OpenVPN → 新增 OpenVPN 配置」导入完整的 `.ovpn`。证书和私钥需内嵌在文件中。如需账号认证，在节点表单填写用户名和密码。确认隧道 DNS 后保存。若要用 Xray 或 Sing-box 节点作前置代理，VPN 服务端须支持 TCP。
2. 在「总览面板 → 新增设备策略」选择工作电脑的 DHCP 租约，核对 MAC 与固定 IPv4，启用 IP/MAC 绑定。将模式设为「代理」，选择刚保存的 OpenVPN 节点。
3. 新建的设备策略默认停用。启用这条规则，点击「保存并应用」，然后让电脑重新获取 DHCP 租约。
4. 在「总览面板」按 MAC 查找工作电脑，核对租约、绑定地址和所选出口。在「OpenVPN」页查看「隧道路由已建立」和收发计数，再从工作电脑访问一个仅 VPN 内可达的服务，或核对实际公网出口 IP。

要让整个 LAN 使用同一隧道，在「全局出口」开启「主开关」并选择该 OpenVPN 节点。用「客户端代理」和「路由器本机代理」分别控制 LAN 与路由器自身的流量。

## 网络保护与故障排查

- **OpenVPN 断线**时，分配给该隧道的公网流量保持阻断，避免回落到 WAN。本地资源是否仍可访问，取决于「允许访问本地 LAN」。
- **节点切换网络保护**默认开启。切换期间，直连设备的转发和客户端 DNS 也会暂停。进程、防火墙规则和 HTTPS 连通性验证成功后恢复转发。失败时 Plus 尝试恢复最近验证通过的配置，恢复失败则保持阻断并重试。主动停止 PassWall 会解除切换保护，恢复系统路由。
- **排查切换失败**时，用 LAN IP 打开 LuCI，在「总览面板」查看最近一次切换或回退结果，并查看「运行日志」。对于仅能访问内网的 VPN，在「全局出口 → 代理」将「切换连通性检查地址」设为该隧道可达、证书有效且返回 200 或 204 的 HTTPS 地址。
- **IPv6** 默认在插件的 `lan` 防火墙区域被拒绝。多 LAN 部署需将相应区域加入拒绝列表。EzWrt 专属固件还在系统层关闭 IPv6、RA 和 DHCPv6。

## 升级与备份

Plus 沿用上游包名 `luci-app-passwall` 和配置路径 `/etc/config/passwall`。在线更新从本仓库获取主程序和中文包，按插件版本判断是否更新。Xray、Sing-box 等核心使用各自的上游版本。

升级前可在「全局出口 → 维护」导出插件备份。LuCI 恢复要求备份与目标的主程序版本相同，包修订号（`-rN`）可以不同。备份可能含订阅凭据和 VPN 私钥，请妥善保管。

## EzCNet 远程管理

EzWrt 随附 passwall-EzCNet 插件，默认关闭。在「服务 → passwall-EzCNet」填写服务端 HTTPS 地址和设备 Key 并启用后，路由器会主动连接服务端。你可以在云端管理订阅、预览待导入的节点或切换出口。若云控已修改配置，本地 LuCI 会提示重新载入表单，避免覆盖他人的更改。[云控插件说明](luci-app-passwall-ezcnet/README.md)

## 编译插件

在已安装基础 feeds 的 OpenWrt 源码树或目标 SDK 中，将以下两行置于 `feeds.conf.default` 顶部。若已有 `feeds.conf`，则修改该文件。

```text
src-git passwall_packages https://github.com/Openwrt-Passwall/openwrt-passwall-packages.git;main
src-git passwall_plus https://github.com/Chiiz0/passwall-plus.git;main
```

```sh
./scripts/feeds update passwall_packages passwall_plus
./scripts/feeds install -a -p passwall_packages
./scripts/feeds install -f -p passwall_plus luci-app-passwall
make menuconfig
```

在 `LuCI → Applications → luci-app-passwall` 选中插件和目标固件使用的 nftables 或 iptables 后端。需要 VPN 时勾选 `Include OpenVPN client`，需要前置代理时再勾选 Xray 或 Sing-Box。保存配置后运行以下命令编译软件包。

```sh
make package/feeds/passwall_plus/luci-app-passwall/compile V=s
```

构建完整 EzWrt 镜像时，仓库的构建脚本会使用固定版本的官方 SDK、ImageBuilder 和依赖。宿主机依赖、构建命令及 QEMU 启动验证见[固件构建指南](openwrt/README.md)。

## 开发与反馈

安装 Bash、Python 3、Lua 5.1 和 Node.js 后，可在仓库根目录运行与 CI 相同的回归检查。

```sh
bash openwrt/scripts/check.sh
```

固件发布流程还会在 QEMU 中启动 OpenWrt，用独立 LAN 客户端检查 DHCP 和管理页面，并以实际网络流量验证 nftables/IPv4 切换保护及 OpenVPN 隧道。[固件验证流程](.github/workflows/build-firmware.yml)

反馈故障时，请附上 OpenWrt 版本、设备架构、PassWall Plus 及核心版本、复现步骤和脱敏日志。[报告问题或提出功能建议](https://github.com/Chiiz0/passwall-plus/issues/new/choose)

## 上游与许可

感谢 [OpenWrt PassWall](https://github.com/Openwrt-Passwall/openwrt-passwall) 提供 LuCI 插件及代理功能基础，核心软件包由 [PassWall Packages](https://github.com/Openwrt-Passwall/openwrt-passwall-packages) 提供。本项目采用 [GPL-3.0](LICENSE)，独立的 EzWrt 主题采用 [Apache-2.0](luci-theme-ezwrt/LICENSE)。
