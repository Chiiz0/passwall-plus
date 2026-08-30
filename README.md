## :mega:公告
自 2026 年 6 月 1 日起，Xray Core 内部定时器已自动弃用 `allowInsecure`（跳过证书验证），并要求自签证书必须配置 `pinnedPeerCertSha256`（`pcs` 参数）。

若机场使用自签证书且未提供 `pcs` 参数，节点将无法正常连接。

**解决方法：**

* 向机场获取 `pinnedPeerCertSha256`（`pcs` 参数）；
* 或切换至 Sing-box Core。  

## 设备级出网策略

访问控制支持将局域网设备的 MAC 地址绑定到固定 IPv4，并为每台设备选择直连、全局配置或独立代理节点。

- 开启“IP/MAC 绑定”后，PassWall 会维护对应的永久 DHCP 静态租约。
- 防火墙会同时拒绝“绑定 MAC 使用其他 IPv4”和“其他 MAC 使用绑定 IPv4”的流量，DHCP 请求不受影响。
- 默认拒绝来自 `lan` 防火墙区域的全部 IPv6；可以在访问控制页调整需要拒绝 IPv6 的源区域。
- DHCP 地址、强绑定规则和代理 ACL 使用同一条访问控制配置，保存并应用后一起生效或清理。

每个启用绑定的访问控制条目应只表示一台设备。设备需要重新获取 DHCP 租约后才会切换到新绑定的 IPv4。

### OpenVPN 设备全流量

编译时可选中 `Include OpenVPN client`，然后在节点列表中新建 OpenVPN 节点并粘贴完整的 `.ovpn` 客户端配置。在设备的访问控制条目中启用 IP/MAC 绑定并选择该 OpenVPN 节点，即可让该设备的全部 IPv4 流量（包括 TCP、UDP、ICMP 和 DNS）经独立 TUN 隧道出网。

- PassWall 使用独立策略路由表、TUN 出口 NAT 和转发规则；隧道断开或客户端未安装时，防回落规则会阻断该设备，流量不会切回 WAN。
- 设备发往 53 端口的 TCP/UDP DNS 请求会强制改写到 OpenVPN 节点配置的 IPv4 DNS，并通过隧道路由。
- 可按访问控制条目决定是否保留本地 LAN 访问；IPv6 仍按全局策略明确拒绝。
- OpenVPN 的服务器连接也被限制为 IPv4；配置中的 IPv6 远端、IPv6 TUN 地址和 IPv6 路由会被移除，前置模式下的服务器域名会在启动时预解析为 IPv4。
- OpenVPN 节点可以复用给多个已绑定设备，每个设备仍保留自己的 DHCP 静态租约和 IP/MAC 强绑定。
- 可选择普通 Xray 或 Sing-box 节点作为前置跳板。前置模式通过本机 SOCKS 连接并强制 OpenVPN 使用 TCP，因此 VPN 服务器端点必须支持 TCP。
- 导入配置中的脚本钩子、管理端口、守护进程、外部配置包含、自定义系统路由和代理指令会被移除，只允许 PassWall 生成的生命周期与路由控制。
- 配置使用用户名/密码认证时，请填写 OpenVPN 节点中的用户名和密码字段；导入配置引用的外部认证文件不会直接使用。

## 📌如何能编译到最新代码？

### 方法1：

执行 `./scripts/feeds update -a` 操作前，在 `feeds.conf.default` **顶部**插入如下代码：

```
src-git passwall_packages https://github.com/Openwrt-Passwall/openwrt-passwall-packages.git;main
src-git passwall_luci https://github.com/Openwrt-Passwall/openwrt-passwall.git;main
```

### 方法2：

在 `./scripts/feeds install -a` 操作完成后，执行以下命令：

```shell
# 移除 openwrt feeds 自带的核心库
rm -rf feeds/packages/net/{xray-core,v2ray-geodata,sing-box,chinadns-ng,dns2socks,hysteria,ipt2socks,microsocks,naiveproxy,shadowsocks-rust,shadowsocksr-libev,simple-obfs,tcping,v2ray-plugin,xray-plugin,geoview,shadow-tls}
git clone https://github.com/Openwrt-Passwall/openwrt-passwall-packages package/passwall-packages

# 移除 openwrt feeds 过时的luci版本
rm -rf feeds/luci/applications/luci-app-passwall
git clone https://github.com/Openwrt-Passwall/openwrt-passwall package/passwall-luci
```
