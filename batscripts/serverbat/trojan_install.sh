#!/bin/bash
# install.sh - Debian 12 一键安装 Trojan-Go 管理脚本
# curl -O "https://riancyman.github.io/batscripts/serverbat/install.sh"
# sudo bash install.sh


# 状态文件路径
INSTALL_STATUS_DIR="/etc/trojan-go"
STATUS_FILE="${INSTALL_STATUS_DIR}/install_status.conf"

# 颜色定义
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
PLAIN="\033[0m"

# 外部资源URL
GITHUB_API_URL="https://api.github.com/repos/p4gefau1t/trojan-go/releases/latest"
NGINX_KEY_URL="https://nginx.org/keys/nginx_signing.key"
ACME_INSTALL_URL="https://get.acme.sh"

# 安装依赖
install_dependencies() {
    # 检查并安装 python3
    if ! command -v python3 >/dev/null 2>&1; then
        log "INFO" "正在安装 python3..."
        apt update
        apt install -y python3
    else
        log "INFO" "python3 已安装"
    fi

    # 检查并安装 ufw
    if ! command -v ufw >/dev/null 2>&1; then
        log "INFO" "正在安装 ufw..."
        apt update
        apt install -y ufw
    else
        log "INFO" "ufw 已安装"
    fi
}

# 检查端口是否被占用
check_port() {
    local port=$1
    if ss -tuln | grep -q ":${port} "; then
        return 1
    fi
    return 0
}

# 检查系统资源
check_system_resources() {
    # 检查内存
    local mem_total=$(free -m | awk '/^Mem:/{print $2}')
    if [ $mem_total -lt 512 ]; then
        log "ERROR" "系统内存不足，建议至少512M内存"
        return 1
    fi
    
    # 检查磁盘空间
    local disk_free=$(df -m / | awk 'NR==2 {print $4}')
    if [ $disk_free -lt 1024 ]; then
        log "ERROR" "磁盘空间不足，建议至少1GB可用空间"
        return 1
    fi
    
    return 0
}

# 初始化状态文件
init_status_file() {
    mkdir -p "$INSTALL_STATUS_DIR"
    if [ ! -f "$STATUS_FILE" ]; then
        cat > "$STATUS_FILE" << EOF
SYSTEM_PREPARED=0
NGINX_INSTALLED=0
CERT_INSTALLED=0
TROJAN_INSTALLED=0
UFW_CONFIGURED=0
BBR_INSTALLED=0
DOMAIN=""
PORT="443"
PASSWORD=""
EOF
    fi
    chmod 600 "$STATUS_FILE"
}

# 读取状态
get_status() {
    local key=$1
    if [ -f "$STATUS_FILE" ]; then
        grep "^${key}=" "$STATUS_FILE" | cut -d'=' -f2
    fi
}

# 设置状态
set_status() {
    local key=$1
    local value=$2
    if [ -f "$STATUS_FILE" ]; then
        if grep -q "^${key}=" "$STATUS_FILE"; then
            sed -i "s|^${key}=.*|${key}=${value}|" "$STATUS_FILE"
        else
            echo "${key}=${value}" >> "$STATUS_FILE"
        fi
    fi
}

# 日志函数
log() {
    local type=$1
    local msg=$2
    local color=$PLAIN
    
    case "${type}" in
        "ERROR") color=$RED ;;
        "SUCCESS") color=$GREEN ;;
        "WARNING") color=$YELLOW ;;
    esac
    
    echo -e "${color}[$(date '+%Y-%m-%d %H:%M:%S')] [${type}] ${msg}${PLAIN}"
}

# 检查是否需要确认重新安装
check_reinstall() {
    local component=$1
    local status_key=$2
    if [ "$(get_status $status_key)" = "1" ]; then
        read -p "${component}已安装，是否重新安装？[y/N] " answer
        if [[ "${answer,,}" != "y" ]]; then
            return 1
        fi
    fi
    return 0
}

# 系统环境准备函数
prepare_system() {
    if ! check_reinstall "系统环境" "SYSTEM_PREPARED"; then
        return 0
    fi

    log "INFO" "准备系统环境..."
    
    # 检查系统资源
    if ! check_system_resources; then
        return 1
    fi
    
    # 更新系统
    apt update
    if [ $? -ne 0 ]; then
        log "ERROR" "系统更新失败"
        return 1
    fi

    # 安装基础软件包
    apt install -y curl wget unzip git ufw
    if [ $? -ne 0 ]; then
        log "ERROR" "基础软件包安装失败"
        return 1
    fi

    set_status SYSTEM_PREPARED 1
    log "SUCCESS" "系统环境准备完成"
    return 0
}

# 安装 Nginx
install_nginx() {
    if ! check_reinstall "Nginx" "NGINX_INSTALLED"; then
        return 0
    fi

    log "INFO" "开始安装 Nginx..."

    # 安装依赖
    apt install -y gnupg2 ca-certificates lsb-release debian-archive-keyring

    # 添加 Nginx 官方源
    curl -fsSL https://nginx.org/keys/nginx_signing.key | gpg --dearmor -o /usr/share/keyrings/nginx-archive-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] http://nginx.org/packages/debian $(lsb_release -cs) nginx" > /etc/apt/sources.list.d/nginx.list

    # 更新并安装 Nginx
    apt update
    apt install -y nginx

    if [ $? -ne 0 ]; then
        log "ERROR" "Nginx 安装失败"
        return 1
    fi

    # 创建临时目录
    mkdir -p /tmp/web

    # 伪装站点选择
    echo "请选择伪装站点类型:"
    echo "1. 简单个人主页"
    echo "2. 技术博客"
    echo "3. 图片站"
    echo "4. 下载站"
    echo "5. 自定义网站"

    read -p "请选择 [1-5]: " site_type

    case "$site_type" in
        1)
            # 简单个人主页
            cat > /usr/share/nginx/html/index.html << 'EOF'
<!DOCTYPE html>
<html>
<head>
    <title>John Doe - Personal Page</title>
    <style>
        body { font-family: Arial, sans-serif; line-height: 1.6; margin: 0; padding: 20px; }
        .container { max-width: 800px; margin: 0 auto; }
        h1 { color: #333; }
        p { color: #666; }
    </style>
</head>
<body>
    <div class="container">
        <h1>Welcome to My Personal Page</h1>
        <p>I am a software developer with a passion for technology and innovation.</p>
        <h2>About Me</h2>
        <p>With over 5 years of experience in web development, I specialize in creating efficient and elegant solutions.</p>
        <h2>Contact</h2>
        <p>Email: john.doe@example.com</p>
    </div>
</body>
</html>
EOF
            ;;
        2)
            # 技术博客
            cat > /usr/share/nginx/html/index.html << 'EOF'
<!DOCTYPE html>
<html>
<head>
    <title>Tech Blog</title>
    <style>
        body { font-family: Arial, sans-serif; line-height: 1.6; margin: 0; padding: 20px; background: #f4f4f4; }
        .container { max-width: 800px; margin: 0 auto; background: white; padding: 20px; border-radius: 5px; }
        .post { margin-bottom: 20px; padding-bottom: 20px; border-bottom: 1px solid #eee; }
        h1 { color: #333; }
        h2 { color: #444; }
        p { color: #666; }
    </style>
</head>
<body>
    <div class="container">
        <h1>Latest in Technology</h1>
        <div class="post">
            <h2>Understanding Cloud Computing</h2>
            <p>Cloud computing has revolutionized how we think about infrastructure...</p>
        </div>
        <div class="post">
            <h2>The Future of AI</h2>
            <p>Artificial Intelligence continues to evolve at a rapid pace...</p>
        </div>
    </div>
</body>
</html>
EOF
            ;;
        3)
            # 图片站
            cat > /usr/share/nginx/html/index.html << 'EOF'
<!DOCTYPE html>
<html>
<head>
    <title>Photography Portfolio</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 0; padding: 20px; background: #000; color: #fff; }
        .container { max-width: 1200px; margin: 0 auto; }
        .gallery { display: grid; grid-template-columns: repeat(auto-fill, minmax(300px, 1fr)); gap: 20px; }
        .gallery-item { background: #333; padding: 10px; }
        h1 { text-align: center; color: #fff; }
    </style>
</head>
<body>
    <div class="container">
        <h1>Photography Portfolio</h1>
        <div class="gallery">
            <div class="gallery-item">Nature Photography</div>
            <div class="gallery-item">Urban Photography</div>
            <div class="gallery-item">Portrait Photography</div>
        </div>
    </div>
</body>
</html>
EOF
            ;;
        4)
            # 下载站
            cat > /usr/share/nginx/html/index.html << 'EOF'
<!DOCTYPE html>
<html>
<head>
    <title>Download Center</title>
    <style>
        body { font-family: Arial, sans-serif; line-height: 1.6; margin: 0; padding: 20px; }
        .container { max-width: 800px; margin: 0 auto; }
        .download-item { background: #f4f4f4; padding: 20px; margin-bottom: 20px; border-radius: 5px; }
        h1 { color: #333; }
        h2 { color: #444; }
        .button { display: inline-block; padding: 10px 20px; background: #007bff; color: white; text-decoration: none; border-radius: 5px; }
    </style>
</head>
<body>
    <div class="container">
        <h1>Download Center</h1>
        <div class="download-item">
            <h2>Software v1.0</h2>
            <p>Latest version with new features and improvements</p>
            <a href="#" class="button">Download</a>
        </div>
    </div>
</body>
</html>
EOF
            ;;
        5)
            read -p "请输入你的自定义网站URL（html格式）: " custom_url
            if [ -n "$custom_url" ]; then
                curl -o /usr/share/nginx/html/index.html "$custom_url"
                if [ $? -ne 0 ]; then
                    log "ERROR" "下载自定义网站失败，使用默认页面"
                    cat > /usr/share/nginx/html/index.html << 'EOF'
<!DOCTYPE html>
<html>
<head>
    <title>Welcome</title>
    <style>
        body { font-family: Arial, sans-serif; text-align: center; padding: 50px; }
    </style>
</head>
<body>
    <h1>Welcome to our website!</h1>
    <p>We're currently updating our content. Please check back soon.</p>
</body>
</html>
EOF
                fi
            fi
            ;;
        *)
            log "ERROR" "无效的选择，使用默认页面"
            ;;
    esac

    # 配置 Nginx
    cat > /etc/nginx/conf.d/default.conf << 'EOF'
server {
    listen 80;
    listen [::]:80;
    server_name _;
    root /usr/share/nginx/html;
    index index.html index.htm;

    location / {
        try_files $uri $uri/ =404;
    }

    # 禁止访问敏感文件
    location ~ .*\.(git|zip|rar|sql|conf|env)$ {
        deny all;
    }

    # 错误页面
    error_page 404 /404.html;
    error_page 500 502 503 504 /50x.html;
    location = /50x.html {
        root /usr/share/nginx/html;
    }
}
EOF

    # 设置目录权限
    chown -R nginx:nginx /usr/share/nginx/html
    chmod -R 755 /usr/share/nginx/html

    # 启动 Nginx
    systemctl daemon-reload
    systemctl enable nginx
    systemctl start nginx

    # 验证 Nginx 是否成功启动
    if ! systemctl is-active --quiet nginx; then
        log "ERROR" "Nginx 启动失败"
        return 1
    fi

    set_status NGINX_INSTALLED 1
    log "SUCCESS" "Nginx 安装配置完成"
    return 0
}

# 申请 SSL 证书
install_cert() {
    if ! check_reinstall "SSL证书" "CERT_INSTALLED"; then
        return 0
    fi

    local domain
    read -p "请输入你的域名：" domain
    if [ -z "$domain" ]; then
        log "ERROR" "域名不能为空"
        return 1
    fi

    local email
    read -p "请输入您的邮箱(用于证书申请和更新通知)：" email
    if [ -z "$email" ] || ! echo "$email" | grep "@" > /dev/null; then
        log "ERROR" "请输入有效的邮箱地址"
        return 1
    fi

    local token
    read -p "请输入您的 DuckDNS token：" token
    if [ -z "$token" ]; then
        log "ERROR" "DuckDNS token 不能为空"
        return 1
    fi

    # 准备工作
    log "INFO" "开始准备..."
    apt update
    apt install -y curl socat

    # 创建证书目录
    mkdir -p /etc/trojan-go/cert
    chmod 755 /etc/trojan-go/cert

    # 停止 web 服务
    systemctl stop nginx 2>/dev/null

    # 安装 acme.sh
    log "INFO" "安装 acme.sh..."
    curl https://get.acme.sh | sh -s email="$email"
    if [ $? -ne 0 ]; then
        log "ERROR" "acme.sh 安装失败"
        return 1
    fi

    source "/root/.acme.sh/acme.sh.env"

    # 设置 DuckDNS API
    export DuckDNS_Token="$token"

    # 申请证书（使用 DNS 模式）
    log "INFO" "申请证书..."
    /root/.acme.sh/acme.sh --issue \
        --dns dns_duckdns \
        -d "${domain}" \
        --force \
        --server letsencrypt \
        --debug \
        --log "/var/log/acme.sh.log"

    if [ $? -ne 0 ]; then
        log "ERROR" "证书申请失败"
        cat /var/log/acme.sh.log
        return 1
    fi

    # 复制证书文件
    log "INFO" "正在安装证书..."
    \cp -f "/root/.acme.sh/${domain}_ecc/${domain}.cer" "/etc/trojan-go/cert/${domain}.pem"
    \cp -f "/root/.acme.sh/${domain}_ecc/${domain}.key" "/etc/trojan-go/cert/${domain}.key"

    if [ ! -f "/etc/trojan-go/cert/${domain}.pem" ] || [ ! -f "/etc/trojan-go/cert/${domain}.key" ]; then
        log "ERROR" "证书安装失败"
        ls -la "/root/.acme.sh/${domain}_ecc/"
        return 1
    fi

    # 设置权限
    chmod 644 "/etc/trojan-go/cert/${domain}.pem"
    chmod 644 "/etc/trojan-go/cert/${domain}.key"

    systemctl start nginx 2>/dev/null

    set_status CERT_INSTALLED 1
    set_status DOMAIN "${domain}"
    
    log "SUCCESS" "SSL 证书配置完成"
    
    # 显示证书信息
    echo -e "\n证书位置："
    echo "证书文件: /etc/trojan-go/cert/${domain}.pem"
    echo "私钥文件: /etc/trojan-go/cert/${domain}.key"
    
    return 0
}

# 安装 Trojan-Go
install_trojan() {
    if ! check_reinstall "Trojan-Go" "TROJAN_INSTALLED"; then
        return 0
    fi

    local domain=$(get_status DOMAIN)
    if [ -z "$domain" ]; then
        log "ERROR" "请先完成证书配置"
        return 1
    fi

    log "INFO" "开始安装 Trojan-Go..."

    # 配置端口
    local port
    while true; do
        read -p "请输入 Trojan-Go 端口 [默认443]: " port
        if [ -z "$port" ]; then
            port=443
            break
        elif [[ "$port" =~ ^[1-9][0-9]*$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
            if check_port $port; then
                break
            else
                log "ERROR" "端口 $port 已被占用，请选择其他端口"
            fi
        else
            log "ERROR" "请输入1-65535之间的有效端口号"
        fi
    done

    # 生成随机密码
    local password=$(openssl rand -base64 16)
    log "INFO" "已生成随机密码: $password"

    # 创建必要目录
    mkdir -p /usr/local/bin
    mkdir -p /usr/local/share/trojan-go
    mkdir -p /etc/trojan-go

    # 下载最新版本
    local latest_version=$(curl -s https://api.github.com/repos/p4gefau1t/trojan-go/releases/latest | grep -oP '"tag_name": "\K[^"]+')
    if [ -z "$latest_version" ]; then
        log "ERROR" "无法获取 Trojan-Go 最新版本"
        return 1
    fi

    local download_url="https://download.fastgit.org/p4gefau1t/trojan-go/releases/download/${latest_version}/trojan-go-linux-amd64.zip"
    
    # 下载并安装
    wget -O /tmp/trojan-go.zip "$download_url" || wget -O /tmp/trojan-go.zip "https://github.com/p4gefau1t/trojan-go/releases/download/${latest_version}/trojan-go-linux-amd64.zip"
    
    if [ ! -f "/tmp/trojan-go.zip" ]; then
        log "ERROR" "Trojan-Go 下载失败"
        return 1
    fi

    # 解压安装
    unzip -o /tmp/trojan-go.zip -d /tmp/trojan-go/
    mv /tmp/trojan-go/trojan-go /usr/local/bin/
    chmod +x /usr/local/bin/trojan-go

    # 复制 GeoIP 数据文件
    mv /tmp/trojan-go/geoip.dat /usr/local/share/trojan-go/
    mv /tmp/trojan-go/geosite.dat /usr/local/share/trojan-go/

    # 配置 Trojan-Go
    cat > /etc/trojan-go/config.json << EOF
{
    "run_type": "server",
    "local_addr": "0.0.0.0",
    "local_port": ${port},
    "remote_addr": "127.0.0.1",
    "remote_port": 80,
    "password": [
        "${password}"
    ],
    "ssl": {
        "cert": "/etc/trojan-go/cert/${domain}.pem",
        "key": "/etc/trojan-go/cert/${domain}.key",
        "sni": "${domain}",
        "alpn": [
            "h2",
            "http/1.1"
        ],
        "session_ticket": true,
        "reuse_session": true,
        "fallback_addr": "127.0.0.1",
        "fallback_port": 80,
        "fingerprint": "chrome"
    },
    "tcp": {
        "no_delay": true,
        "keep_alive": true,
        "prefer_ipv4": false
    },
    "websocket": {
        "enabled": true,
        "path": "/ws",
        "hostname": "${domain}"
    },
    "mysql": {
        "enabled": false
    }
}
EOF

    # 创建 systemd 服务
    cat > /etc/systemd/system/trojan-go.service << EOF
[Unit]
Description=Trojan-Go - A unofficial build of Trojan-Go
Documentation=https://p4gefau1t.github.io/trojan-go/
After=network.target nss-lookup.target

[Service]
Type=simple
StandardError=journal
User=root
AmbientCapabilities=CAP_NET_BIND_SERVICE
ExecStart=/usr/local/bin/trojan-go -config /etc/trojan-go/config.json
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=10s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

    # 更新 Nginx 配置
    cat > /etc/nginx/conf.d/default.conf << EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${domain};
    root /usr/share/nginx/html;
    
    # 强制跳转 HTTPS
    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${domain};
    root /usr/share/nginx/html;
    
    ssl_certificate /etc/trojan-go/cert/${domain}.pem;
    ssl_certificate_key /etc/trojan-go/cert/${domain}.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;
    ssl_ciphers "ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305";
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;
    ssl_session_tickets off;
    ssl_stapling on;
    ssl_stapling_verify on;
    resolver 8.8.8.8 8.8.4.4 valid=300s;
    resolver_timeout 5s;

    location /ws {
        proxy_redirect off;
        proxy_http_version 1.1;
        proxy_pass http://127.0.0.1:80;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }

    location / {
        try_files \$uri \$uri/ /index.html;
    }
}
EOF

    # 重启服务
    systemctl daemon-reload
    systemctl enable trojan-go
    systemctl restart trojan-go
    systemctl restart nginx

    # 验证服务状态
    if ! systemctl is-active --quiet trojan-go; then
        log "ERROR" "Trojan-Go 启动失败，请检查日志"
        journalctl -u trojan-go.service --no-pager
        return 1
    fi

    # 清理临时文件
    rm -rf /tmp/trojan-go /tmp/trojan-go.zip

    # 保存配置
    set_status TROJAN_INSTALLED 1
    set_status PORT ${port}
    set_status PASSWORD ${password}

    log "SUCCESS" "Trojan-Go 安装配置完成"
    
    # 显示客户端配置信息
    echo -e "\n${GREEN}客户端配置信息：${PLAIN}"
    echo -e "地址(address): ${domain}"
    echo -e "端口(port): ${port}"
    echo -e "密码(password): ${password}"
    echo -e "加密方式(security): tls"
    echo -e "传输协议: ws+tls"
    echo -e "WebSocket 路径: /ws"

    return 0
}

# 配置 UFW 防火墙
configure_ufw() {
    if ! check_reinstall "UFW防火墙" "UFW_CONFIGURED"; then
        return 0
    fi

    log "INFO" "配置 UFW 防火墙..."

    # 安装 UFW
    apt update
    apt install -y ufw

    # 获取当前 SSH 端口
    local current_ssh_port=$(ss -tlpn | grep sshd | awk '{print $4}' | cut -d: -f2 | head -n1)
    current_ssh_port=${current_ssh_port:-22}

    # 获取 Trojan-Go 端口
    local trojan_port=$(get_status PORT)
    trojan_port=${trojan_port:-443}

    # 确认配置
    echo -e "${YELLOW}防火墙配置确认：${PLAIN}"
    echo "1. SSH 端口: $current_ssh_port"
    echo "2. Trojan-Go 端口: $trojan_port"
    echo "3. HTTP 端口: 80"
    echo -e "${RED}警告：错误的防火墙配置可能导致服务器无法访问！${PLAIN}"
    read -p "确认继续配置防火墙？(y/N) " confirm
    if [[ "${confirm,,}" != "y" ]]; then
        return 0
    fi

    # 重置防火墙规则
    ufw --force reset

    # 设置默认策略
    ufw default deny incoming
    ufw default allow outgoing

    # 允许 SSH
    ufw allow $current_ssh_port/tcp comment 'SSH'

    # 允许 HTTP
    ufw allow 80/tcp comment 'HTTP'

    # 允许 Trojan-Go
    ufw allow $trojan_port/tcp comment 'Trojan-Go'

    # 启用 UFW
    echo "y" | ufw enable
    ufw reload

    # 保存配置
    set_status UFW_CONFIGURED 1
    set_status SSH_PORT $current_ssh_port

    # 显示防火墙状态
    ufw status numbered

    log "SUCCESS" "UFW 防火墙配置完成"
    
    # 安全提示
    echo -e "${YELLOW}重要提示：${PLAIN}"
    echo "1. 请确保 SSH 端口 $current_ssh_port 能正常连接"
    echo "2. 如需添加其他端口，使用: ufw allow 端口号/tcp"
    echo "3. 查看防火墙状态：ufw status"
    
    return 0
}

# 安装 BBR 加速
install_bbr() {
    if ! check_reinstall "BBR加速" "BBR_INSTALLED"; then
        return 0
    fi

    log "INFO" "配置 BBR 加速..."

    # 检查内核版本
    local kernel_version=$(uname -r)
    log "INFO" "当前内核版本: $kernel_version"

    # 检查是否已启用BBR
    if lsmod | grep -q bbr; then
        log "SUCCESS" "BBR 已经启用"
        set_status BBR_INSTALLED 1
        return 0
    fi

    # 检查系统版本
    if ! grep -qi "debian" /etc/os-release; then
        log "ERROR" "仅支持 Debian 系统"
        return 1
    fi

    # 配置 BBR
    cat > /etc/sysctl.d/99-bbr.conf << EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_fin_timeout=30
net.ipv4.tcp_keepalive_time=1200
net.ipv4.tcp_max_syn_backlog=8192
net.ipv4.tcp_max_tw_buckets=5000
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_syncookies=1
net.ipv4.tcp_timestamps=1
net.ipv4.tcp_sack=1
net.ipv4.tcp_window_scaling=1
EOF

    # 应用配置
    sysctl --system

    # 验证BBR是否启用
    if lsmod | grep -q bbr; then
        log "SUCCESS" "BBR 配置成功"
        set_status BBR_INSTALLED 1
        
        # 显示网络状态
        echo -e "\n当前网络配置："
        sysctl net.ipv4.tcp_congestion_control
        sysctl net.core.default_qdisc
        
        return 0
    else
        log "ERROR" "BBR 配置失败"
        return 1
    fi
}

# 显示配置信息
show_config() {
   local domain=$(get_status DOMAIN)
   local password=$(get_status PASSWORD)
   local port=$(get_status PORT)
   
   echo "===================== Trojan-Go 配置信息 ====================="
   echo -e "域名: ${GREEN}${domain}${PLAIN}"
   echo -e "端口: ${GREEN}${port}${PLAIN}"
   echo -e "密码: ${GREEN}${password}${PLAIN}"
   echo ""
   echo "客户端配置信息："
   echo "  地址(address): ${domain}"
   echo "  端口(port): ${port}"
   echo "  密码(password): ${password}"
   echo "  加密方式(security): tls"
   echo "=========================================================="
}

# 查看服务状态
show_status() {
   echo "===================== 服务运行状态 ====================="
   echo -e "\n[ Nginx 状态 ]"
   systemctl status nginx --no-pager | grep -E "Active:|running"
   
   echo -e "\n[ Trojan-Go 状态 ]"
   systemctl status trojan-go --no-pager | grep -E "Active:|running"
   
   echo -e "\n[ UFW 状态 ]"
   ufw status verbose
   
   echo -e "\n[ BBR 状态 ]"
   if lsmod | grep -q bbr; then
       echo -e "${GREEN}BBR: 已启用${PLAIN}"
       sysctl net.ipv4.tcp_congestion_control
   else
       echo -e "${RED}BBR: 未启用${PLAIN}"
   fi
   
   echo -e "\n[ 端口监听状态 ]"
   ss -tulpn | grep -E ':80|:443'
   echo "======================================================"
}

# 重启所有服务
restart_services() {
   log "INFO" "重启所有服务..."
   
   systemctl restart nginx
   systemctl restart trojan-go
   
   # 验证服务状态
   local has_error=0
   
   if ! systemctl is-active --quiet nginx; then
       log "ERROR" "Nginx 重启失败"
       has_error=1
   fi
   
   if ! systemctl is-active --quiet trojan-go; then
       log "ERROR" "Trojan-Go 重启失败"
       has_error=1
   fi
   
   if [ $has_error -eq 0 ]; then
       log "SUCCESS" "所有服务重启成功"
       show_status
   fi
}

# 卸载所有组件
uninstall_all() {
   log "WARNING" "即将卸载所有组件..."
    echo -e "${RED}该操作将会：${PLAIN}"
    echo "1. 停止并删除 Trojan-Go 服务"
    echo "2. 停止并删除 Nginx 服务"
    echo "3. 删除所有证书和配置文件"
    echo "4. 删除所有日志文件"
    echo "5. 重置防火墙配置"
    
    read -p "确定要卸载所有组件吗？[y/N] " answer
    if [[ "${answer,,}" != "y" ]]; then
        return 0
    fi

    log "INFO" "开始卸载组件..."

    # 1. 停止和禁用服务
    log "INFO" "停止服务..."
    systemctl stop trojan-go
    systemctl disable trojan-go
    systemctl stop nginx
    systemctl disable nginx

    # 2. 卸载 Trojan-Go
    log "INFO" "删除 Trojan-Go..."
    rm -rf /etc/trojan-go
    rm -f /usr/local/bin/trojan-go
    rm -f /etc/systemd/system/trojan-go.service
    rm -rf /usr/local/share/trojan-go
    rm -rf /var/log/trojan-go    # 删除日志目录

    # 3. 卸载 Nginx
    log "INFO" "删除 Nginx..."
    apt remove --purge -y nginx nginx-common
    rm -rf /etc/nginx
    rm -rf /var/log/nginx

    # 4. 清理证书
    log "INFO" "清理证书..."
    if [ -d ~/.acme.sh ]; then
        ~/.acme.sh/acme.sh --uninstall
        rm -rf ~/.acme.sh
    fi

    # 5. 重置防火墙
    log "INFO" "重置防火墙..."
    ufw --force reset
    ufw disable

    # 6. 删除状态文件
    rm -f "$STATUS_FILE"

    log "SUCCESS" "所有组件已卸载完成"
    
    read -p "是否需要重启服务器？[y/N] " reboot_answer
    if [[ "${reboot_answer,,}" == "y" ]]; then
        reboot
    fi
}

# 显示菜单
show_menu() {
   clear
   echo "========== Trojan-Go 安装管理系统 =========="
   echo -e " 1. 系统环境准备 $(if [ "$(get_status SYSTEM_PREPARED)" = "1" ]; then echo "${GREEN}[OK]${PLAIN}"; fi)"
   echo -e " 2. 安装配置 Nginx $(if [ "$(get_status NGINX_INSTALLED)" = "1" ]; then echo "${GREEN}[OK]${PLAIN}"; fi)"
   echo -e " 3. 申请配置 SSL 证书 $(if [ "$(get_status CERT_INSTALLED)" = "1" ]; then echo "${GREEN}[OK]${PLAIN}"; fi)"
   echo -e " 4. 安装配置 Trojan-Go $(if [ "$(get_status TROJAN_INSTALLED)" = "1" ]; then echo "${GREEN}[OK]${PLAIN}"; fi)"
   echo -e " 5. 配置 UFW 防火墙 $(if [ "$(get_status UFW_CONFIGURED)" = "1" ]; then echo "${GREEN}[OK]${PLAIN}"; fi)"
   echo -e " 6. 安装配置 BBR 加速 $(if [ "$(get_status BBR_INSTALLED)" = "1" ]; then echo "${GREEN}[OK]${PLAIN}"; fi)"
   echo " 7. 查看配置信息"
   echo " 8. 查看运行状态"
   echo " 9. 重启所有服务"
   echo " 10. 卸载所有组件"
   echo " 11. 检查诊断信息"
   echo " 0. 退出"
   echo "==========================================="
}

check_trojan_status() {
    echo "=================== 诊断信息 ==================="
    
    # 获取实际配置的端口
    local trojan_port=$(get_status PORT)
    
    # 检查证书
    echo "1. 检查证书："
    local domain=$(get_status DOMAIN)
    if [ -f "/etc/trojan-go/cert/${domain}.pem" ] && [ -f "/etc/trojan-go/cert/${domain}.key" ]; then
        echo "   证书文件存在"
        ls -l /etc/trojan-go/cert/${domain}.pem /etc/trojan-go/cert/${domain}.key
    else
        echo "   证书文件缺失"
    fi
    
    # 检查端口占用
    echo -e "\n2. 检查端口监听："
    if [ -n "$trojan_port" ]; then
        ss -tulpn | grep -E ":80|:443|:${trojan_port}"
    else
        ss -tulpn | grep -E ":80|:443"
        echo "   警告: 未找到 Trojan-Go 端口配置"
    fi
    
    # 检查 Trojan-Go 配置
    echo -e "\n3. Trojan-Go 配置检查："
    if [ -f "/etc/trojan-go/config.json" ]; then
        echo "   配置文件存在"
        # 使用 python 来格式化检查 JSON
        if command -v python3 >/dev/null 2>&1; then
            if python3 -c "import json; json.load(open('/etc/trojan-go/config.json'))" 2>/dev/null; then
                echo "   配置文件格式正确"
            else
                echo "   配置文件格式错误"
            fi
        else
            echo "   未安装 python3，无法验证 JSON 格式"
        fi
    else
        echo "   配置文件不存在"
    fi
    
    # 检查服务状态
    echo -e "\n4. 服务状态："
    systemctl status trojan-go | grep -E "Active:|running"
    
    # 检查防火墙
    echo -e "\n5. 防火墙状态："
    if command -v ufw >/dev/null 2>&1; then
        ufw status verbose
    else
        echo "   UFW 未安装"
    fi
    
    # 检查日志
    echo -e "\n6. 最近的错误日志："
    if [ -f "/var/log/trojan-go/error.log" ]; then
        tail -n 10 /var/log/trojan-go/error.log
    else
        echo "   日志文件不存在"
    fi
    
    echo "=============================================="
}

# 主函数
main() {
   # 检查是否为root用户
   if [[ $EUID -ne 0 ]]; then
       echo -e "${RED}错误：请使用 root 用户运行此脚本${PLAIN}"
       exit 1
   fi

   # 检查是否为 Debian 系统
   if ! grep -qi "debian" /etc/os-release; then
       echo -e "${RED}错误：此脚本仅支持 Debian 系统${PLAIN}"
       exit 1
   fi

   # 初始化
   init_status_file
   
   # 主循环
   while true; do
       show_menu
       read -p "请选择操作[0-11]: " choice
       case "${choice}" in
           0)
               log "INFO" "退出脚本"
               exit 0
               ;;
           1)
               prepare_system
               ;;
           2)
               install_nginx
               ;;
           3)
               install_cert
               ;;
           4)
               install_trojan
               ;;
           5)
               configure_ufw
               ;;
           6)
               install_bbr
               ;;
           7)
               show_config
               ;;
           8)
               show_status
               ;;
           9)
               restart_services
               ;;
           10)
               uninstall_all
               ;;
           11)
               check_trojan_status
               ;;
           *)
               log "ERROR" "无效的选择"
               ;;
       esac
       echo
       read -p "按回车键继续..." </dev/tty
   done
}

# 启动脚本
main "$@"