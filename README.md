# wzyoct/script

个人脚本合集。每个脚本独立目录，各有详细的使用说明。

## 脚本列表

| 脚本 | 说明 |
|------|------|
| [debian-vps-setup](./scripts/debian-vps-setup/) | Debian VPS 安全加固 — SSH 端口、密钥登录、fail2ban、BBR、Swap 等 |

## 一键执行

点击复制下面整条命令，粘贴到 VPS 回车即可：

### debian-vps-setup

```bash
curl -fsSL https://raw.githubusercontent.com/wzyoct/script/main/scripts/debian-vps-setup/debian-vps-setup.sh -o setup.sh || wget -O setup.sh https://raw.githubusercontent.com/wzyoct/script/main/scripts/debian-vps-setup/debian-vps-setup.sh && bash setup.sh
```

> 💡 **提示：** 如果 `curl` 和 `wget` 都未安装（Debian 最小化系统），先执行 `apt update && apt install -y curl wget`。

## 添加新脚本

1. 复制模板：`cp -r scripts/_template scripts/你的脚本名`
2. 修改 `README.md` 和脚本文件
3. 在根 `README.md` 的脚本列表中添加一行

---

> 更多脚本陆续添加中。
