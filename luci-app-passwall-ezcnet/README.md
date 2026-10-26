# passwall-EzCNet 路由器插件 · v0.2.0

云控服务端位于固件仓库同级 `../passwall-EzCNet`，包含中文网页、账号管理、任务 API、Docker Compose 和 Caddy 部署配置。默认域名是 `passwall.ezcnet.com`。

在 LuCI“服务 → passwall-EzCNet”填写服务端 HTTPS 地址和网页生成的设备 Key，启用并保存。设备主动连接，不需要公网 IP，也不开放入站管理端口。默认云控关闭、Key 为空；本地调度进程由 procd 管理，关闭云控连接不会停用已经配置的订阅定时器。

## 管理能力

- 订阅新增、编辑、删除、单个/全部更新，下载方式、User-Agent、过滤关键词和自动更新间隔。
- URI、Base64、Clash YAML 节点导入预览，重复检测与错误条目；确认时应用相同下载快照。
- OpenVPN 文件导入/替换、账号密码、DNS 和前置代理，复用 Plus 的配置清理逻辑。
- 节点搜索/分组/重命名/删除/切换、订阅上次节点记忆，以及普通代理节点连通性测试。
- 稳定节点 ID、主节点/ACL/SOCKS/HAProxy/分流/负载均衡/URLTest/前置与落地代理引用保护。
- 异步 worker 与独立心跳，持久化回执、配置冲突检测、备份与失联回滚。

全局配置白名单为 `enabled`、`node`、`tcp_proxy_mode`、`udp_proxy_mode`、`localhost_proxy`、`client_proxy`、`openvpn_global_allow_lan`、`acl_enable`。已有分流节点切换保留原生 DNS 模式适配。任意 ACL/分流规则编辑和远程 Shell 不在云控协议中。

## 应用保护

云端任务先验证整个 `/etc/config/passwall` 的 SHA-256，在独立 UCI 目录中构造完整配置。与原生订阅/规则更新共享互斥锁；配置与日志同步落盘后才替换活动文件，释放更新锁后重启服务。云端确认超时 90 秒时恢复备份；若本地已再次修改配置，拒绝覆盖。原生 LuCI 不使用云控事务锁，应用云端变更时应避免同时在 LuCI 保存配置。

`/etc/passwall_ezcnet/pending.json` 保存阶段和回执，断电后不会盲目重放写入。该目录的 `rollback` 包含敏感配置，权限为目录 700/文件 600。预览和下载临时文件在 RAM 中，预览 10 分钟失效，重启后需重新生成。正常心跳仅写 RAM；配置变更、回执和定时更新记录写入持久化存储。

接管后的订阅标记 `ezcnet_managed=1`，由云控插件维护稳定来源 ID。原生订阅更新器跳过这些订阅；手动更新请在云控网页操作，定时更新在云端离线时仍运行。空订阅不清空原节点，被引用的已下线节点标记为保留。删除引用节点必须指定合适替代节点，不能产生循环引用。

## 安装与版本

必须同时升级主插件 **26.10.22-r4** 和云控插件 **0.2.0-r1**。云控使用主插件新提供的只读解析接口，不能只替换旧版主插件上的 Agent。

标准构建输出位于 `dist/openwrt/25.12.5/`，包含 APK、校验和及完整固件；GitHub Release 从专属固件 `25.12.5-r5` 起提供这些文件。先核对 `SHA256SUMS`，再在匹配的 OpenWrt 25.12.5 固件上安装：

```sh
apk add --allow-untrusted /tmp/luci-app-passwall-26.10.22-r4.apk /tmp/luci-app-passwall-ezcnet-0.2.0-r1.apk
/etc/init.d/passwall-ezcnet restart
```

`--allow-untrusted` 仅用于本地 SDK 签名的软件包。旧版 opkg 固件需要使用相应 SDK 编译 IPK。源码已接入 `openwrt/scripts/build-firmware.sh`，依赖 PassWall Plus 的单主节点结构，不兼容旧的 `tcp_node/udp_node` 结构。

```sh
logread -e passwall-ezcnet
cat /var/run/passwall-ezcnet-status.json
/etc/init.d/passwall-ezcnet restart
```

完整部署、密钥备份和测试方法见服务端 README。单设备上限为 50 个订阅/2000 个节点；单次导入 256 KiB、OpenVPN 128 KiB、一次延迟测试最多 20 个普通节点。OpenVPN 独立延迟测试和自动故障切换不包含在此版本中。
