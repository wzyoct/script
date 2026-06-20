# Debian VPS 安全加固脚本

一键加固 Debian 11 / 12 / 13 VPS 的安全配置。

## 功能

- ✅ 自定义 SSH 端口（默认 2222）
- ✅ 禁用密码登录，仅允许密钥认证
- ✅ Root 密钥登录（禁止密码）
- ✅ fail2ban 防暴力破解（自动适配 journald / auth.log）
- ✅ 自动安全更新 (unattended-upgrades)
- ✅ 自动 Swap（内存 ≤2GB 时）
- ✅ 时区设置 (Asia/Shanghai)
- ✅ TCP/BBR 网络优化（显式加载内核模块）
- ✅ 完成后自动验证所有配置
- ✅ 一键恢复脚本（SSH 连不上时在控制台执行）
- ✅ `--dry-run` 模式预览不执行

## 一键使用

```bash
# 先预览（不实际执行）
bash debian-vps-setup.sh --dry-run

# 正式执行
bash debian-vps-setup.sh
```

## 一行命令拉取执行

```bash
curl -fsSL https://raw.githubusercontent.com/wzyoct/script/main/debian-vps-setup.sh -o setup.sh && bash setup.sh
```

## 从零开始：重装 Debian 13 + 安全加固

### 第一步：重装系统（在当前 VPS 上执行）

**方式 A：使用密码登录（简单快速）**

```bash
curl -O https://raw.githubusercontent.com/bin456789/reinstall/main/reinstall.sh || wget -O reinstall.sh https://raw.githubusercontent.com/bin456789/reinstall/main/reinstall.sh
bash reinstall.sh debian 13 --ssh-port 2222 --password "ECMAzfSyVDADvz%T"
reboot
```

**方式 B：使用 SSH 密钥登录（更安全）**

```bash
curl -O https://raw.githubusercontent.com/bin456789/reinstall/main/reinstall.sh
bash reinstall.sh debian 13 \
  --ssh-key "你的SSH公钥" \
  --ssh-port 2222
reboot
```

### 第二步：SSH 登录新系统并加固

```bash
ssh -p 2222 root@你的VPS-IP
curl -fsSL https://raw.githubusercontent.com/wzyoct/script/main/debian-vps-setup.sh -o setup.sh && bash setup.sh
```

## 紧急恢复

如果 SSH 连不上，在 VPS 控制台（VNC）执行：

```bash
bash /root/ssh-restore.sh
```

## ⚠️ 注意事项

- 执行前确保有 VPS 控制台备用访问（VNC/Console）
- 脚本会自动备份原 SSH 配置到 `/etc/ssh/sshd_config.bak.*`
- 脚本会自动备份 `sshd_config.d/` 到 `/root/sshd_config.d.bak.*`
- 修改密钥：编辑脚本中 `BUILTIN_PUB_KEY` 变量
