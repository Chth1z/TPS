# TPS (TProxyShell)

基于 sing-box 核心的 Android Magisk 透明代理模块

## 功能特性

* **核心组件**：
    * 集成 sing-box 作为核心
* **代理模式**：
    * 支持 TPROXY（默认，支持 UDP）和 REDIRECT 模式
* **网络支持**：
    * 支持 IPv4 和 IPv6 双栈代理
    * 支持 DNS 劫持（TProxy/Redirect 模式）
    * 支持绕过中国大陆 IP（基于 ipset）
* **接口控制**：
    * 可独立控制移动数据、Wi-Fi、热点、USB 网络接口的代理开关
* **过滤机制**：
    * **应用过滤**：基于 UID 的黑/白名单模式
    * **MAC 过滤**：针对热点连接设备的 MAC 地址黑/白名单过滤
    * **防环路**：内置路由标记和用户组保护，防止流量死循环
* **订阅管理**：
    * 内置 subconverter 和 jq 工具
    * 模块启动时/使用update.sh自动下载、转换、节点筛选（按地区正则表达式）及配置文件生成

## 目录结构

所有模块文件位于 `/data/adb/box/`：

* `bin/`：存放 sing-box 核心
* `conf/`：存放 `config.json` 和 `settings.ini`
* `run/`：存放运行时 PID、日志和临时文件
* `scripts/`：存放功能脚本
* `tools/`：存放 jq、subconverter 及转换模板

## 配置说明

主配置文件路径：`/data/adb/box/conf/settings.ini`

关键配置项：
* `SUBSCRIPTION_URL`：订阅链接
* `PROXY_MODE`：0=自动, 1=TProxy, 2=Redirect
* `APP_PROXY_MODE`：1=黑名单, 2=白名单
* `PROXY_APPS_LIST`：需要代理的应用包名列表
* `BYPASS_CN_IP`：绕过大陆 IP
* `UPDATE_INTERVAL`：更新订阅最小时间间隔