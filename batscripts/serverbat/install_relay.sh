#!/bin/bash
# install_relay.sh - Debian 12 一键安装 HAProxy 中转管理脚本

# 状态文件路径
INSTALL_STATUS_DIR="/etc/haproxy-relay"
STATUS_FILE="${INSTALL_STATUS_DIR}/install_status.conf"

# 颜色定义
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
PLAIN="\033[0m"

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

# 初始化状态文件
init_status_file() {
    mkdir -p "$INSTALL_STATUS_DIR"
    if [ ! -f "$STATUS_FILE" ]; then
        cat > "$STATUS_FILE" << EOF
SYSTEM_PREPARED=0
HAPROXY_INSTALLED=0
NGINX_INSTALLED=0
CERT_INSTALLED=0
MULTI_PORT_CONFIGURED=0
UFW_CONFIGURED=0
BBR_INSTALLED=0
UPSTREAM_SERVERS=""
LISTEN_PORTS=""
STATS_USER=""
STATS_PASS=""
DOMAIN_NAME=""
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
        # 验证设置是否成功
        if [ "$(get_status $key)" = "$value" ]; then
            return 0
        fi
    fi
    return 1
}

# 检查端口是否被占用
check_port() {
    local port=$1
    if ss -tuln | grep -q ":${port} "; then
        return 1
    fi
    return 0
}

# 系统环境准备
prepare_system() {
   log "INFO" "准备系统环境..."
   
   # 预先配置 kexec-tools
   echo 'LOAD_KEXEC=false' > /etc/default/kexec
   
   # 设置非交互模式
   export DEBIAN_FRONTEND=noninteractive
   
   # 更新系统
   log "INFO" "更新系统..."
   if ! apt-get update; then
       log "ERROR" "系统更新失败"
       return 1
   fi
   
   # 更新软件包
   log "INFO" "更新软件包..."
   if ! apt-get -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" upgrade; then
       log "ERROR" "软件包更新失败"
       return 1
   fi
   
   # 安装基础包
   log "INFO" "安装基础软件包..."
   if ! apt-get install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" \
       curl wget unzip ufw socat nginx python3; then
       log "ERROR" "基础软件包安装失败"
       return 1
   fi
   
   # 验证必要软件是否安装成功
   local required_packages=("curl" "wget" "unzip" "ufw" "socat" "nginx" "python3")
   local missing_packages=()
   
   for pkg in "${required_packages[@]}"; do
       if ! command -v $pkg >/dev/null 2>&1; then
           missing_packages+=($pkg)
       fi
   done
   
   if [ ${#missing_packages[@]} -ne 0 ]; then
       log "ERROR" "以下软件包安装失败: ${missing_packages[*]}"
       return 1
   fi
   
   # 设置系统优化参数
   log "INFO" "设置系统参数..."
   
   # 确保目录存在
   mkdir -p /etc/sysctl.d

   # 备份原有配置（如果存在）
   if [ -f "/etc/sysctl.d/99-custom.conf" ]; then
       mv /etc/sysctl.d/99-custom.conf /etc/sysctl.d/99-custom.conf.bak.$(date +%Y%m%d%H%M%S)
   fi

   # 创建新的配置文件
   cat > /etc/sysctl.d/99-custom.conf << EOF
# 系统优化参数
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_keepalive_time = 1200
net.ipv4.ip_local_port_range = 10000 65000
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_max_tw_buckets = 5000
net.ipv4.tcp_max_orphans = 3276800
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_window_scaling = 1

# 网络性能优化
net.core.somaxconn = 32768
net.core.netdev_max_backlog = 32768
net.ipv4.tcp_max_syn_backlog = 16384
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 87380 16777216

# 连接优化
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_congestion_control = cubic

# 安全性优化
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
EOF

   # 设置文件权限
   chmod 644 /etc/sysctl.d/99-custom.conf

   # 应用系统参数
   if ! sysctl -p /etc/sysctl.d/99-custom.conf > /dev/null 2>&1; then
       log "WARNING" "系统参数设置可能未完全生效，但不影响基本功能"
   else
       log "SUCCESS" "系统参数设置成功"
   fi

   # 验证参数是否生效
   local sysctl_status=0
   local check_params=(
       "net.ipv4.tcp_fastopen"
       "net.ipv4.tcp_syncookies"
       "net.ipv4.tcp_fin_timeout"
       "net.core.somaxconn"
       "net.ipv4.tcp_max_syn_backlog"
   )

   for param in "${check_params[@]}"; do
       if ! sysctl -n $param >/dev/null 2>&1; then
           sysctl_status=1
           log "WARNING" "参数 $param 可能未正确设置"
       fi
   done

   if [ $sysctl_status -eq 1 ]; then
       log "WARNING" "部分系统参数可能未生效，但不影响基本功能"
   fi
   
   # 设置时区
   log "INFO" "设置系统时区..."
   if ! timedatectl set-timezone Asia/Shanghai; then
       log "ERROR" "时区设置失败"
       return 1
   fi

   # 验证所有配置
   local check_status=0
   
   # 检查时区
   if [ "$(timedatectl show --property=Timezone --value)" != "Asia/Shanghai" ]; then
       log "ERROR" "时区设置验证失败"
       check_status=1
   fi
   
   # 检查系统参数文件
   if [ ! -f "/etc/sysctl.d/99-custom.conf" ]; then
       log "ERROR" "系统参数文件不存在"
       check_status=1
   fi
   
   # 检查必要服务
   for service in nginx ufw; do
       if ! systemctl is-enabled $service >/dev/null 2>&1; then
           log "WARNING" "服务 $service 可能未正确启用"
           systemctl enable $service >/dev/null 2>&1
       fi
   done
   
   # 如果所有检查都通过，设置状态
   if [ $check_status -eq 0 ]; then
       # 确保状态目录存在
       mkdir -p "$INSTALL_STATUS_DIR"
       chmod 700 "$INSTALL_STATUS_DIR"
       
       if set_status SYSTEM_PREPARED 1; then
           log "SUCCESS" "系统环境准备完成"
           return 0
       else
           log "ERROR" "状态设置失败"
           return 1
       fi
   else
       log "ERROR" "系统环境准备失败"
       return 1
   fi
}

# 申请SSL证书
install_cert() {
    log "INFO" "开始申请SSL证书..."
   
   # 获取域名
   local domain
   if [ -n "$(get_status DOMAIN_NAME)" ]; then
       read -p "已配置域名$(get_status DOMAIN_NAME)，是否使用新域名？[y/N] " change_domain
       if [[ "${change_domain,,}" != "y" ]]; then
           domain=$(get_status DOMAIN_NAME)
       fi
   fi
   
   if [ -z "$domain" ]; then
       read -p "请输入你的域名：" domain
       if [ -z "$domain" ]; then
           log "ERROR" "域名不能为空"
           return 1
       fi
   fi
   
   # 创建证书目录
   mkdir -p /etc/haproxy/certs
   chmod 700 /etc/haproxy/certs

   # 检查并停止相关服务
   log "INFO" "检查并停止相关服务..."
   
   # 检查并停止Nginx
    if systemctl is-enabled nginx >/dev/null 2>&1; then
        log "INFO" "停止Nginx服务..."
        if ! systemctl stop nginx; then
            log "WARNING" "通过systemctl停止Nginx失败，尝试强制停止..."
            pkill -f nginx
        fi
        
        # 验证Nginx是否真的停止了
        if pgrep -f nginx >/dev/null; then
            log "ERROR" "无法停止Nginx服务"
            return 1
        else
            log "INFO" "Nginx服务已停止"
        fi
    else
        log "INFO" "Nginx服务未安装，跳过"
    fi

    # 确保80端口真的释放了
    sleep 2  # 等待端口完全释放
    if ss -tuln | grep -q ':80 '; then
        log "ERROR" "80端口仍被占用，检查占用进程..."
        lsof -i :80
        return 1
    else
        log "INFO" "80端口已释放"
    fi
   
   # 检查HAProxy
   if systemctl is-enabled haproxy >/dev/null 2>&1; then
       log "INFO" "停止HAProxy服务..."
       systemctl stop haproxy
   else
       log "INFO" "HAProxy服务未安装，跳过"
   fi

   # 确保端口80空闲
   if ss -tuln | grep -q ':80 '; then
       log "ERROR" "端口80被占用，无法申请证书"
       return 1
   fi

   # 安装 acme.sh
   if [ ! -f ~/.acme.sh/acme.sh ]; then
       log "INFO" "安装 acme.sh..."
       curl -fsSL https://get.acme.sh | sh -s email=admin@${domain}
       if [ $? -ne 0 ]; then
           log "ERROR" "acme.sh 安装失败"
           return 1
       fi
       source ~/.bashrc
   else
       log "INFO" "acme.sh 已安装，尝试更新..."
       ~/.acme.sh/acme.sh --upgrade
   fi

   # 申请证书
   log "INFO" "申请SSL证书..."
   # 先清理之前的申请记录（如果有的话）
    ~/.acme.sh/acme.sh --remove -d ${domain} --force >/dev/null 2>&1

    # 申请并添加调试参数
    ~/.acme.sh/acme.sh --issue -d ${domain} --standalone \
        --keylength ec-256 \
        --key-file /etc/haproxy/certs/${domain}.key \
        --fullchain-file /etc/haproxy/certs/${domain}.pem \
        --force \
        --debug \
        --log "/var/log/acme.sh.log"


    if [ $? -ne 0 ]; then
        log "ERROR" "证书申请失败"
        log "INFO" "查看详细日志: cat /var/log/acme.sh.log"
        # 输出最后几行错误信息
        tail -n 10 /var/log/acme.sh.log
        
        # 检查常见问题
        if dig +short ${domain} | grep -q '^[0-9]\+\.[0-9]\+\.[0-9]\+\.[0-9]\+$'; then
            local domain_ip=$(dig +short ${domain})
            local server_ip=$(curl -s ifconfig.me)
            if [ "$domain_ip" != "$server_ip" ]; then
                log "ERROR" "域名解析IP（${domain_ip}）与服务器IP（${server_ip}）不匹配"
                log "INFO" "请确保域名已正确解析到服务器IP"
            fi
        else
            log "ERROR" "域名解析失败，请检查域名配置"
        fi
        
        # 重启之前运行的服务
        if systemctl is-enabled nginx >/dev/null 2>&1; then
            systemctl start nginx
        fi
        if systemctl is-enabled haproxy >/dev/null 2>&1; then
            systemctl start haproxy
        fi
        return 1
    fi

    # 合并证书和私钥为HAProxy格式
    cat /etc/haproxy/certs/${domain}.pem /etc/haproxy/certs/${domain}.key > \
        /etc/haproxy/certs/${domain}.pem.combined

    # 设置证书权限
    chmod 600 /etc/haproxy/certs/${domain}.pem.combined
    chown haproxy:haproxy /etc/haproxy/certs/${domain}.pem.combined

    # 验证证书
    if [ -f "/etc/haproxy/certs/${domain}.pem.combined" ]; then
        if ! openssl x509 -in "/etc/haproxy/certs/${domain}.pem" -noout -checkend 0; then
            log "ERROR" "证书无效或已过期"
            return 1
        fi

        # 更新Nginx SSL配置
        if ! update_nginx_ssl "${domain}"; then
            log "WARNING" "Nginx SSL配置更新失败，但证书已安装"
        fi
    else
        log "ERROR" "证书文件不存在"
        return 1
    fi

    # 配置证书自动更新
    ~/.acme.sh/acme.sh --install-cert -d ${domain} \
        --key-file /etc/haproxy/certs/${domain}.key \
        --fullchain-file /etc/haproxy/certs/${domain}.pem \
        --reloadcmd "cat /etc/haproxy/certs/${domain}.pem /etc/haproxy/certs/${domain}.key > /etc/haproxy/certs/${domain}.pem.combined && chmod 600 /etc/haproxy/certs/${domain}.pem.combined && chown haproxy:haproxy /etc/haproxy/certs/${domain}.pem.combined && systemctl reload haproxy"

    # 重启服务
    log "INFO" "重启相关服务..."
    
    if systemctl is-enabled nginx >/dev/null 2>&1; then
        systemctl start nginx
    fi
    
    if systemctl is-enabled haproxy >/dev/null 2>&1; then
        systemctl start haproxy
    fi

    # 验证服务状态
    local service_status=0
    
    if systemctl is-enabled nginx >/dev/null 2>&1; then
        if ! systemctl is-active --quiet nginx; then
            log "ERROR" "Nginx启动失败"
            service_status=1
        fi
    fi
    
    if systemctl is-enabled haproxy >/dev/null 2>&1; then
        if ! systemctl is-active --quiet haproxy; then
            log "ERROR" "HAProxy启动失败"
            service_status=1
        fi
    fi

    if [ $service_status -eq 0 ]; then
        # 保存配置
        set_status CERT_INSTALLED 1
        set_status DOMAIN_NAME ${domain}
        log "SUCCESS" "SSL证书配置完成"
        return 0
    else
        log "ERROR" "服务启动失败"
        return 1
    fi
}

# 配置Nginx伪装站点
configure_nginx() {
   log "INFO" "配置Nginx伪装站点..."
   
   # 检查是否需要重新配置域名
   local domain
   if [ -n "$(get_status DOMAIN_NAME)" ]; then
       domain=$(get_status DOMAIN_NAME)
   else
       read -p "请输入你的域名: " domain
       if [ -z "$domain" ]; then
           log "ERROR" "域名不能为空"
           return 1
       fi
   fi

   # 创建必要的目录
   mkdir -p /etc/nginx/conf.d
   mkdir -p /var/log/nginx

   # 创建 nginx.conf 主配置文件
   cat > /etc/nginx/nginx.conf << 'EOF'
user www-data;
worker_processes auto;
pid /run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;

events {
   worker_connections 768;
   multi_accept on;
}

http {
   sendfile on;
   tcp_nopush on;
   tcp_nodelay on;
   keepalive_timeout 65;
   types_hash_max_size 2048;

   include /etc/nginx/mime.types;
   default_type application/octet-stream;

   access_log /var/log/nginx/access.log;
   error_log /var/log/nginx/error.log;

   gzip on;
   gzip_disable "msie6";

   include /etc/nginx/conf.d/*.conf;
}
EOF

   # 创建 mime.types 文件
   cat > /etc/nginx/mime.types << 'EOF'
types {
   text/html                             html htm shtml;
   text/css                              css;
   text/xml                              xml;
   image/gif                             gif;
   image/jpeg                            jpeg jpg;
   application/javascript                js;
   application/atom+xml                  atom;
   application/rss+xml                   rss;

   image/png                             png;
   image/svg+xml                         svg svgz;
   image/tiff                            tif tiff;
   image/x-icon                          ico;
   image/x-jng                           jng;
   image/webp                            webp;

   application/json                      json;
   application/pdf                       pdf;
   application/zip                       zip;

   audio/midi                            mid midi kar;
   audio/mpeg                            mp3;
   audio/ogg                             ogg;
   audio/x-m4a                           m4a;

   video/mp4                             mp4;
   video/mpeg                            mpeg mpg;
   video/webm                            webm;
   video/x-flv                           flv;
}
EOF

   # 创建日志目录
   mkdir -p /var/log/nginx
   chown -R www-data:www-data /var/log/nginx

   # 配置虚拟主机
   cat > /etc/nginx/conf.d/default.conf << EOF
server {
   listen 80;
   server_name ${domain};
   root /var/www/html;
   index index.html;
   
   location / {
       try_files \$uri \$uri/ =404;
   }

   # 禁止访问特定文件
   location ~ /\. {
       deny all;
       access_log off;
       log_not_found off;
   }
   
   location = /favicon.ico {
       log_not_found off;
       access_log off;
   }

   location = /robots.txt {
       log_not_found off;
       access_log off;
   }
}
EOF

   # 配置伪装站点
   echo "请选择伪装站点类型："
   echo "1. 个人博客"
   echo "2. 企业官网"
   echo "3. 图片站"
   echo "4. 下载站"
   echo "5. 自定义网站"
   read -p "请选择 [1-5]: " site_type
   
   # 确保网站目录存在
   mkdir -p /var/www/html
   
   # 根据选择配置不同的伪装站点
   case "$site_type" in
       1)
           # 个人博客模板
           cat > /var/www/html/index.html << 'EOF'
<!DOCTYPE html>
<html>
<head>
   <title>My Personal Blog</title>
   <meta charset="utf-8">
   <style>
       body { font-family: Arial, sans-serif; line-height: 1.6; margin: 0; padding: 20px; }
       .container { max-width: 800px; margin: 0 auto; }
       h1 { color: #333; }
       .article { margin-bottom: 20px; padding: 20px; background: #f9f9f9; }
   </style>
</head>
<body>
   <div class="container">
       <h1>Welcome to My Blog</h1>
       <div class="article">
           <h2>Latest Post</h2>
           <p>This is my latest blog post about technology and life...</p>
       </div>
   </div>
</body>
</html>
EOF
           ;;
       2)
           # 企业官网模板
           cat > /var/www/html/index.html << 'EOF'
<!DOCTYPE html>
<html>
<head>
   <title>Company Name</title>
   <meta charset="utf-8">
   <style>
       body { font-family: Arial, sans-serif; margin: 0; padding: 0; }
       .header { background: #2c3e50; color: white; padding: 40px 20px; text-align: center; }
       .content { max-width: 1000px; margin: 0 auto; padding: 20px; }
   </style>
</head>
<body>
   <div class="header">
       <h1>Welcome to Our Company</h1>
       <p>Leading Innovation in Technology</p>
   </div>
   <div class="content">
       <h2>About Us</h2>
       <p>We are a leading technology company...</p>
   </div>
</body>
</html>
EOF
           ;;
       3)
           # 图片站模板
           cat > /var/www/html/index.html << 'EOF'
<!DOCTYPE html>
<html>
<head>
   <title>Photo Gallery</title>
   <meta charset="utf-8">
   <style>
       body { background: #000; color: #fff; font-family: Arial, sans-serif; }
       .gallery { display: grid; grid-template-columns: repeat(auto-fill, minmax(200px, 1fr)); gap: 20px; padding: 20px; }
       .photo { background: #333; height: 200px; display: flex; align-items: center; justify-content: center; }
   </style>
</head>
<body>
   <div class="gallery">
       <div class="photo">Photo 1</div>
       <div class="photo">Photo 2</div>
       <div class="photo">Photo 3</div>
   </div>
</body>
</html>
EOF
           ;;
       4)
           # 下载站模板
           cat > /var/www/html/index.html << 'EOF'
<!DOCTYPE html>
<html>
<head>
   <title>Download Center</title>
   <meta charset="utf-8">
   <style>
       body { font-family: Arial, sans-serif; margin: 0; padding: 20px; }
       .download-item { background: #f5f5f5; padding: 20px; margin: 10px 0; border-radius: 5px; }
       .button { background: #4CAF50; color: white; padding: 10px 20px; text-decoration: none; border-radius: 3px; }
   </style>
</head>
<body>
   <h1>Download Center</h1>
   <div class="download-item">
       <h3>Software v1.0</h3>
       <p>Latest version with new features</p>
       <a href="#" class="button">Download</a>
   </div>
</body>
</html>
EOF
           ;;
       5)
           # 自定义网站
           read -p "请输入自定义网站URL: " custom_url
           if [ -n "$custom_url" ]; then
               wget -O /var/www/html/index.html "$custom_url"
               if [ $? -ne 0 ]; then
                   log "ERROR" "下载自定义网站失败，使用默认页面"
                   echo "<h1>Welcome</h1>" > /var/www/html/index.html
               fi
           fi
           ;;
   esac

   # 设置目录权限
   chown -R www-data:www-data /var/www/html
   chmod -R 755 /var/www/html
   
   # 检查Nginx配置语法
   if ! nginx -t; then
       log "ERROR" "Nginx配置检查失败"
       return 1
   fi
   
   # 重启Nginx
   systemctl restart nginx
   sleep 2  # 等待服务启动
   
   # 全面检查Nginx状态
   local nginx_status=0
   # 检查服务是否运行
   if ! systemctl is-active --quiet nginx; then
       log "ERROR" "Nginx服务未运行"
       nginx_status=1
   fi
   
   # 检查配置文件是否存在
   if [ ! -f "/etc/nginx/conf.d/default.conf" ]; then
       log "ERROR" "Nginx配置文件不存在"
       nginx_status=1
   fi
   
   # 检查网站文件是否存在
   if [ ! -f "/var/www/html/index.html" ]; then
       log "ERROR" "网站文件不存在"
       nginx_status=1
   fi
   
   # 检查80端口是否在监听
   if ! ss -tuln | grep -q ':80 '; then
       log "ERROR" "80端口未监听"
       nginx_status=1
   fi
   
   # 保存域名到状态文件
   if ! set_status DOMAIN_NAME "${domain}"; then
       log "ERROR" "保存域名配置失败"
       return 1
   fi
   
   if [ $nginx_status -eq 0 ]; then
       if set_status NGINX_INSTALLED 1; then
           log "SUCCESS" "Nginx伪装站点配置完成"
           return 0
       else
           log "ERROR" "状态保存失败"
           return 1
       fi
   else
       log "ERROR" "Nginx配置失败"
       return 1
   fi
}

# 更新Nginx SSL配置
update_nginx_ssl() {
    local domain=$1
    log "INFO" "更新Nginx SSL配置..."

    # 检查证书是否存在
    if [ ! -f "/etc/haproxy/certs/${domain}.pem" ] || [ ! -f "/etc/haproxy/certs/${domain}.key" ]; then
        log "ERROR" "证书文件不存在"
        return 1
    fi

    # 更新Nginx配置
    cat > /etc/nginx/conf.d/default.conf << EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${domain};
    return 301 https://\$server_name\$request_uri;
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${domain};
    root /var/www/html;
    index index.html;

    ssl_certificate /etc/haproxy/certs/${domain}.pem;
    ssl_certificate_key /etc/haproxy/certs/${domain}.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;
    ssl_prefer_server_ciphers off;
    ssl_session_timeout 1d;
    ssl_session_cache shared:SSL:50m;
    ssl_session_tickets off;

    location / {
        try_files \$uri \$uri/ =404;
    }

    location ~ /\. {
        deny all;
        access_log off;
        log_not_found off;
    }
}
EOF

    # 检查配置
    if ! nginx -t; then
        log "ERROR" "Nginx SSL配置检查失败"
        return 1
    fi

    # 重启Nginx
    systemctl restart nginx

    if systemctl is-active --quiet nginx; then
        log "SUCCESS" "Nginx SSL配置更新完成"
        return 0
    else
        log "ERROR" "Nginx重启失败"
        return 1
    fi
}

# 安装 HAProxy
install_haproxy() {
    log "INFO" "开始安装 HAProxy..."
    
    # 安装HAProxy
    apt-get update
    apt-get install -y haproxy

    local status=$?
    if [ $status -ne 0 ]; then
        # 如果默认安装失败，尝试使用官方源
        curl -fsSL https://haproxy.debian.net/bernat.debian.org.gpg | gpg --dearmor -o /usr/share/keyrings/haproxy.debian.net.gpg
        echo "deb [signed-by=/usr/share/keyrings/haproxy.debian.net.gpg] http://haproxy.debian.net bookworm-backports-2.8 main" > /etc/apt/sources.list.d/haproxy.list
        apt-get update
        apt-get install -y haproxy=2.8.\*
        status=$?
    fi

    if [ $status -ne 0 ]; then
        log "ERROR" "HAProxy 安装失败"
        return 1
    fi

    # 创建证书目录
    mkdir -p /etc/haproxy/certs
    chmod 700 /etc/haproxy/certs

    # 验证安装
    if ! command -v haproxy >/dev/null 2>&1; then
        log "ERROR" "HAProxy未正确安装"
        return 1
    fi

    # 验证版本
    local version=$(haproxy -v 2>&1 | head -n1)
    log "INFO" "HAProxy版本: $version"

    # 验证服务状态
    if ! systemctl is-enabled haproxy >/dev/null 2>&1; then
        log "ERROR" "HAProxy服务未启用"
        return 1
    fi

    # 验证配置目录
    if [ ! -d "/etc/haproxy" ]; then
        log "ERROR" "HAProxy配置目录不存在"
        return 1
    fi

    # 验证证书目录权限
    if [ ! -d "/etc/haproxy/certs" ] || [ "$(stat -c '%a' /etc/haproxy/certs)" != "700" ]; then
        log "ERROR" "证书目录权限配置错误"
        return 1
    fi

    # 所有检查通过后设置状态
    if set_status HAPROXY_INSTALLED 1; then
        log "SUCCESS" "HAProxy 安装完成"
        return 0
    else
        log "ERROR" "状态设置失败"
        return 1
    fi
}

# 配置端口转发
configure_relay() {
    log "INFO" "配置端口转发..."
    
    # 检查证书
    local domain=$(get_status DOMAIN_NAME)
    if [ ! -f "/etc/haproxy/certs/${domain}.pem.combined" ]; then
        log "ERROR" "未找到SSL证书，请先配置证书"
        return 1
    fi
    
    # 配置状态页面认证
    local stats_user
    local stats_pass
    while true; do
        read -p "请设置状态页面用户名 [默认随机生成]: " stats_user
        if [ -z "$stats_user" ]; then
            stats_user=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | fold -w 8 | head -n 1)
            log "INFO" "已生成随机用户名: $stats_user"
            break
        elif [[ "${#stats_user}" -ge 3 ]]; then
            break
        else
            log "ERROR" "用户名长度必须大于等于3位"
        fi
    done

    while true; do
        read -p "请设置状态页面密码 [默认随机生成]: " stats_pass
        if [ -z "$stats_pass" ]; then
            stats_pass=$(tr -dc 'a-zA-Z0-9!@#$%^&*()' < /dev/urandom | fold -w 16 | head -n 1)
            log "INFO" "已生成随机密码: $stats_pass"
            break
        elif [[ "${#stats_pass}" -ge 6 ]]; then
            break
        else
            log "ERROR" "密码长度必须大于等于6位"
        fi
    done

    # 询问上游服务器数量
    read -p "请输入上游服务器数量: " server_count
    
    # 准备配置文件
    cp /etc/haproxy/haproxy.cfg /etc/haproxy/haproxy.cfg.bak
    
    # 创建基础配置
    cat > /etc/haproxy/haproxy.cfg << EOF
global
    log /dev/log local0
    log /dev/log local1 notice
    chroot /var/lib/haproxy
    stats socket /run/haproxy/admin.sock mode 660 level admin expose-fd listeners
    stats timeout 30s
    user haproxy
    group haproxy
    daemon
    # SSL设置
    ssl-default-bind-ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305
    ssl-default-bind-ciphersuites TLS_AES_128_GCM_SHA256:TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256
    ssl-default-bind-options no-sslv3 no-tlsv10 no-tlsv11

defaults
    log     global
    mode    tcp
    option  dontlognull
    option  tcplog
    timeout connect 5000
    timeout client  50000
    timeout server  50000

# HTTPS状态页面
listen stats
    bind *:10086 ssl crt /etc/haproxy/certs/${domain}.pem.combined
    mode http
    stats enable
    stats hide-version
    stats uri /
    stats realm Haproxy\ Statistics
    stats auth ${stats_user}:'${stats_pass}'
    stats refresh 10s
    stats admin if TRUE
EOF

    local upstream_servers=""
    local listen_ports=""
    
    for ((i=1; i<=server_count; i++)); do
        read -p "请输入第${i}个上游服务器域名或IP: " server_addr
        read -p "请输入第${i}个上游服务器端口: " server_port
        read -p "请输入本地监听端口 [建议使用8443等]: " listen_port
        
        # 添加转发配置
        cat >> /etc/haproxy/haproxy.cfg << EOF

frontend ft_${listen_port}
    bind *:${listen_port} ssl crt /etc/haproxy/certs/${domain}.pem.combined
    mode tcp
    option tcplog
    default_backend bk_${server_addr}_${server_port}

backend bk_${server_addr}_${server_port}
    mode tcp
    option tcp-check
    server server1 ${server_addr}:${server_port} check inter 2000 rise 2 fall 3
EOF
        
        upstream_servers="${upstream_servers}${server_addr}:${server_port},"
        listen_ports="${listen_ports}${listen_port},"
    done

    if [ -z "$stats_user" ] || [ -z "$stats_pass" ]; then
        log "ERROR" "状态页面认证信息配置失败"
        return 1
    fi

    # 保存配置信息
    set_status STATS_USER "${stats_user}"
    set_status STATS_PASS "${stats_pass}"
    set_status UPSTREAM_SERVERS "${upstream_servers%,}"
    set_status LISTEN_PORTS "${listen_ports%,}"

    # 验证配置是否成功保存
    if [ "$(get_status STATS_USER)" != "$stats_user" ] || \
       [ "$(get_status STATS_PASS)" != "$stats_pass" ] || \
       [ "$(get_status UPSTREAM_SERVERS)" != "${upstream_servers%,}" ] || \
       [ "$(get_status LISTEN_PORTS)" != "${listen_ports%,}" ]; then
        log "ERROR" "配置信息保存失败"
        return 1
    fi
    
    # 检查配置语法
    if ! haproxy -c -f /etc/haproxy/haproxy.cfg; then
        log "ERROR" "配置文件有误，正在回滚..."
        mv /etc/haproxy/haproxy.cfg.bak /etc/haproxy/haproxy.cfg
        return 1
    fi
    
    # 重启服务
    systemctl restart haproxy

    sleep 2  # 等待服务启动
    
    # 检查服务状态和端口
    if ! systemctl is-active --quiet haproxy; then
        log "ERROR" "HAProxy 重启失败"
        return 1
    fi

    # 检查端口是否正在监听
    local listen_status=0
    IFS=',' read -ra PORTS <<< "${listen_ports%,}"
    for port in "${PORTS[@]}"; do
        if ! ss -tuln | grep -q ":${port} "; then
            log "ERROR" "端口 ${port} 未正常监听"
            listen_status=1
            break
        fi
    done

    # 检查状态页面端口
    if ! ss -tuln | grep -q ":10086 "; then
        log "ERROR" "状态页面端口 10086 未正常监听"
        listen_status=1
    fi

    if [ $listen_status -eq 0 ]; then
        set_status MULTI_PORT_CONFIGURED 1
        log "SUCCESS" "端口转发配置完成"
        return 0
    else
        log "ERROR" "端口配置失败"
        return 1
    fi
}

# 配置 UFW 防火墙
configure_ufw() {
    log "INFO" "配置 UFW 防火墙..."

    # 检查SSH端口
    local ssh_port=$(ss -tuln | grep -i ssh | awk '{print $5}' | awk -F: '{print $2}')
    ssh_port=${ssh_port:-22}
    
    # 重置UFW
    ufw --force reset
    
    # 设置默认策略
    ufw default deny incoming
    ufw default allow outgoing
    
    # 允许SSH
    ufw allow ${ssh_port}/tcp
    
    # 允许HTTP和HTTPS（用于伪装网站和证书申请）
    ufw allow 80/tcp
    ufw allow 443/tcp
    
    # 允许HAProxy端口
    local listen_ports=$(get_status LISTEN_PORTS)
    IFS=',' read -ra PORTS <<< "$listen_ports"
    for port in "${PORTS[@]}"; do
        if [ -n "$port" ]; then
            ufw allow ${port}/tcp
        fi
    done
    
    # 允许状态监控端口
    ufw allow 10086/tcp
    
    # 启用UFW
    echo "y" | ufw enable
    
    # 验证UFW状态和端口配置 【新增的验证部分】
    if ! ufw status | grep -q "Status: active"; then
        log "ERROR" "UFW 未成功启用"
        return 1
    fi

    # 验证SSH端口
    if ! ufw status | grep -q "${ssh_port}/tcp"; then
        log "ERROR" "SSH端口 ${ssh_port} 配置失败"
        return 1
    fi

    # 验证HTTP和HTTPS端口
    if ! ufw status | grep -q "80/tcp" || ! ufw status | grep -q "443/tcp"; then
        log "ERROR" "Web端口配置失败"
        return 1
    fi

    # 验证HAProxy端口
    local port_status=0
    local listen_ports=$(get_status LISTEN_PORTS)
    IFS=',' read -ra PORTS <<< "$listen_ports"
    for port in "${PORTS[@]}"; do
        if [ -n "$port" ]; then
            if ! ufw status | grep -q "$port/tcp"; then
                log "ERROR" "端口 $port 配置失败"
                port_status=1
                break
            fi
        fi
    done

    # 验证状态页面端口
    if ! ufw status | grep -q "10086/tcp"; then
        log "ERROR" "状态页面端口配置失败"
        port_status=1
    fi

    if [ $port_status -eq 0 ]; then
        set_status UFW_CONFIGURED 1
        log "SUCCESS" "UFW 防火墙配置完成"
        return 0
    else
        log "ERROR" "UFW 配置失败"
        return 1
    fi
}

# 安装 BBR 加速
install_bbr() {
    log "INFO" "配置 BBR..."
    
    if lsmod | grep -q bbr; then
        log "SUCCESS" "BBR 已经启用"
        set_status BBR_INSTALLED 1
        return 0
    fi
    
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p

    if lsmod | grep -q bbr; then
        set_status BBR_INSTALLED 1
        log "SUCCESS" "BBR 配置完成"
        return 0
    else
        log "ERROR" "BBR 配置失败"
        return 1
    fi
}

# 显示配置信息
show_config() {
    echo "====================== 转发配置信息 ======================"
    
    # 显示域名信息
    local domain=$(get_status DOMAIN_NAME)
    if [ -n "$domain" ]; then
        echo -e "域名: ${GREEN}${domain}${PLAIN}"
    fi
    
    # 显示转发规则
    local upstream_servers=$(get_status UPSTREAM_SERVERS)
    local listen_ports=$(get_status LISTEN_PORTS)
    local stats_user=$(get_status STATS_USER)
    local stats_pass=$(get_status STATS_PASS)
    
    if [ -n "$upstream_servers" ] && [ -n "$listen_ports" ]; then
        IFS=',' read -ra SERVERS <<< "$upstream_servers"
        IFS=',' read -ra PORTS <<< "$listen_ports"
        
        echo -e "\n转发规则："
        for i in "${!SERVERS[@]}"; do
            echo -e "规则 $((i+1)):"
            echo -e "  本地端口: ${GREEN}${PORTS[i]}${PLAIN}"
            echo -e "  上游服务器: ${GREEN}${SERVERS[i]}${PLAIN}"
        done
    fi
    
    echo -e "\nHAProxy 状态页面："
    echo -e "  地址: https://${domain}:10086"
    echo -e "  用户名: ${GREEN}${stats_user}${PLAIN}"
    echo -e "  密码: ${GREEN}${stats_pass}${PLAIN}"
    
    # 显示证书信息
    if [ -f "/etc/haproxy/certs/${domain}.pem.combined" ]; then
        echo -e "\nSSL证书信息："
        echo -e "  证书路径: /etc/haproxy/certs/${domain}.pem.combined"
        echo -e "  自动续期: 已配置"
    fi
    
    echo "======================================================="
}

# 查看服务状态
show_status() {
    echo "====================== 服务运行状态 ======================"
    
    echo -e "\n[ Nginx状态 ]"
    systemctl status nginx --no-pager | grep -E "Active:|running"
    
    echo -e "\n[ HAProxy状态 ]"
    systemctl status haproxy --no-pager | grep -E "Active:|running"
    
    echo -e "\n[ UFW状态 ]"
    ufw status verbose
    
    echo -e "\n[ BBR状态 ]"
    if lsmod | grep -q bbr; then
        echo -e "${GREEN}BBR: 已启用${PLAIN}"
    else
        echo -e "${RED}BBR: 未启用${PLAIN}"
    fi
    
    echo -e "\n[ SSL证书状态 ]"
    local domain=$(get_status DOMAIN_NAME)
    if [ -f "/etc/haproxy/certs/${domain}.pem.combined" ]; then
        echo -e "${GREEN}证书: 已安装${PLAIN}"
        openssl x509 -in /etc/haproxy/certs/${domain}.pem -noout -dates
    else
        echo -e "${RED}证书: 未安装${PLAIN}"
    fi
    
    echo -e "\n[ 端口监听状态 ]"
    ss -tuln | grep -E ':(80|443|10086|'$(get_status LISTEN_PORTS | tr ',' '|')')'
    echo "======================================================="
}

# 重启服务
restart_services() {
    log "INFO" "重启所有服务..."
    
    systemctl restart nginx
    systemctl restart haproxy
    
    local has_error=0
    if ! systemctl is-active --quiet nginx; then
        log "ERROR" "Nginx重启失败"
        has_error=1
    fi
    
    if ! systemctl is-active --quiet haproxy; then
        log "ERROR" "HAProxy重启失败"
        has_error=1
    fi
    
    if [ $has_error -eq 0 ]; then
        log "SUCCESS" "所有服务重启成功"
        show_status
    fi
}

# 卸载组件
uninstall_all() {
    log "WARNING" "即将卸载所有组件..."
    read -p "确定要卸载吗？[y/N] " answer
    if [[ "${answer,,}" != "y" ]]; then
        return 0
    fi
    
    # 停止服务（使用 systemctl list-units 检查）
    for service in nginx haproxy; do
        if systemctl list-units --full -all | grep -Fq "$service.service"; then
            log "INFO" "停止 $service 服务..."
            systemctl stop $service
            systemctl disable $service
        else
            log "INFO" "$service 服务未安装"
        fi
    done
    
    # 卸载软件包（使用 dpkg -l 检查）
    log "INFO" "卸载软件包..."
    local packages_to_remove=()
    for pkg in nginx nginx-common haproxy; do
        if dpkg -l | grep -q "^ii.*$pkg "; then
            packages_to_remove+=($pkg)
        fi
    done
    
    if [ ${#packages_to_remove[@]} -gt 0 ]; then
        apt remove --purge -y "${packages_to_remove[@]}"
    fi
    
    # 清理证书和acme.sh
    if [ -d ~/.acme.sh ]; then
        log "INFO" "清理证书和acme.sh..."
        if [ -f ~/.acme.sh/acme.sh ]; then
            ~/.acme.sh/acme.sh --uninstall
        fi
        rm -rf ~/.acme.sh
    fi
    
    # 清理配置文件和日志
    log "INFO" "清理配置文件和日志..."
    for dir in "/etc/nginx" "/etc/haproxy" "$INSTALL_STATUS_DIR" "/var/www/html" "/var/log/nginx" "/var/log/haproxy"; do
        if [ -d "$dir" ]; then
            rm -rf "$dir"
        fi
    done

    # 清理所有相关日志文件
    log "INFO" "清理日志文件..."
    rm -f /var/log/acme.sh.log           # acme.sh的主日志
    rm -f ~/.acme.sh/*.log               # acme.sh的其他日志
    rm -f ~/.acme.sh/acme.sh.log         # acme.sh的安装日志
    rm -f /root/.acme.sh/*.log           # root用户下的acme.sh日志
    rm -f /root/.acme.sh/acme.sh.log     # root用户下的acme.sh安装日志
    
    # 清理系统服务文件
    log "INFO" "清理系统服务文件..."
    for service in nginx haproxy; do
        local service_file="/etc/systemd/system/$service.service"
        if [ -f "$service_file" ]; then
            rm -f "$service_file"
        fi
    done
    systemctl daemon-reload
    
    # 重置防火墙
    log "INFO" "重置防火墙..."
    if command -v ufw >/dev/null 2>&1; then
        ufw --force reset >/dev/null 2>&1
        ufw disable >/dev/null 2>&1
    fi
    
    # 清理系统参数
    if [ -f "/etc/sysctl.d/99-custom.conf" ]; then
        log "INFO" "清理系统参数..."
        rm -f /etc/sysctl.d/99-custom.conf
        sysctl --system >/dev/null 2>&1
    fi
    
    # 自动清理未使用的依赖
    log "INFO" "清理未使用的依赖..."
    apt autoremove -y >/dev/null 2>&1
    apt clean >/dev/null 2>&1
    
    log "SUCCESS" "卸载完成"
    
    # 询问是否需要重启
    read -p "是否需要重启系统来完成清理？[y/N] " reboot_answer
    if [[ "${reboot_answer,,}" == "y" ]]; then
        log "INFO" "系统将在3秒后重启..."
        sleep 3
        reboot
    fi
}

# 检查是否需要重新安装
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

# 显示菜单
show_menu() {
    clear
    echo "=========== HAProxy 中转管理系统 ==========="
    echo -e " 1. 系统环境准备 $(if [ "$(get_status SYSTEM_PREPARED)" = "1" ]; then echo "${GREEN}[OK]${PLAIN}"; fi)"
    echo -e " 2. 配置伪装站点 $(if [ "$(get_status NGINX_INSTALLED)" = "1" ]; then echo "${GREEN}[OK]${PLAIN}"; fi)"
    echo -e " 3. 申请SSL证书 $(if [ "$(get_status CERT_INSTALLED)" = "1" ]; then echo "${GREEN}[OK]${PLAIN}"; fi)"
    echo -e " 4. 查看证书日志"    # 新添加的选项
    echo -e " 5. 安装 HAProxy $(if [ "$(get_status HAPROXY_INSTALLED)" = "1" ]; then echo "${GREEN}[OK]${PLAIN}"; fi)"
    echo -e " 6. 配置端口转发 $(if [ "$(get_status MULTI_PORT_CONFIGURED)" = "1" ]; then echo "${GREEN}[OK]${PLAIN}"; fi)"
    echo -e " 7. 配置 UFW 防火墙 $(if [ "$(get_status UFW_CONFIGURED)" = "1" ]; then echo "${GREEN}[OK]${PLAIN}"; fi)"
    echo -e " 8. 安装 BBR 加速 $(if [ "$(get_status BBR_INSTALLED)" = "1" ]; then echo "${GREEN}[OK]${PLAIN}"; fi)"
    echo " 9. 查看配置信息"
    echo " 10. 查看运行状态"
    echo " 11. 重启所有服务"
    echo " 12. 卸载所有组件"
    echo " 0. 退出"
    echo "=========================================="
}

# 查看证书日志和诊断信息
view_cert_log() {
    echo "====================== 证书诊断信息 ======================"
   
   # 检查域名解析
   local domain=$(get_status DOMAIN_NAME)
   if [ -n "$domain" ]; then
       echo -e "\n域名解析检查："
       echo "域名: $domain"
       echo "解析IP: $(dig +short ${domain})"
       echo "服务器IP: $(curl -s ifconfig.me)"
   fi

   # 检查端口状态
   echo -e "\n端口状态检查："
   ss -tuln | grep -E ':(80|443)' || echo "80和443端口都未被占用"

   # 检查服务状态
   echo -e "\n服务状态检查："
   echo "Nginx状态: $(systemctl is-active nginx 2>/dev/null || echo '未安装')"
   echo "HAProxy状态: $(systemctl is-active haproxy 2>/dev/null || echo '未安装')"

   # 检查acme.sh安装
   echo -e "\nacme.sh检查："
   if [ -f ~/.acme.sh/acme.sh ]; then
       echo "acme.sh版本: $($HOME/.acme.sh/acme.sh --version 2>&1 | head -n 1)"
       echo "已配置域名: $($HOME/.acme.sh/acme.sh --list 2>/dev/null | grep -v "^Looking" || echo '无')"
   else
       echo "acme.sh未安装"
   fi

   # 查看证书日志
   echo -e "\n证书日志 (最近20行)："
   echo "---------------------------------------------------"
   # 检查所有可能的日志位置
   local log_files=(
       "/var/log/acme.sh.log"
       "~/.acme.sh/acme.sh.log"
       "~/.acme.sh/*.log"
       "/root/.acme.sh/acme.sh.log"
       "/root/.acme.sh/*.log"
   )
   
   local found_logs=0
   for log_file in "${log_files[@]}"; do
       if [ -f "$(eval echo $log_file)" ]; then
           echo "发现日志文件: $(eval echo $log_file)"
           echo "------------------------"
           tail -n 20 "$(eval echo $log_file)"
           echo "------------------------"
           found_logs=1
       fi
   done
   
   if [ $found_logs -eq 0 ]; then
       echo "未找到任何证书日志文件"
   fi
   
   # 证书状态
   if [ -n "$domain" ]; then
       echo -e "\n证书文件检查："
       local cert_files=(/etc/haproxy/certs/${domain}.*)
       if [ -e "${cert_files[0]}" ]; then
           ls -l /etc/haproxy/certs/${domain}.*
           if [ -f "/etc/haproxy/certs/${domain}.pem" ]; then
               echo -e "\n证书有效期："
               openssl x509 -in "/etc/haproxy/certs/${domain}.pem" -noout -dates
               echo -e "\n证书验证："
               if openssl x509 -in "/etc/haproxy/certs/${domain}.pem" -noout -checkend 0; then
                   echo -e "${GREEN}证书有效${PLAIN}"
               else
                   echo -e "${RED}证书已过期${PLAIN}"
               fi
           fi
       else
           echo "未找到证书文件"
       fi
   fi

   # 环境诊断
   echo -e "\n环境诊断："
   echo "---------------------------------------------------"
   echo "操作系统: $(cat /etc/os-release | grep "PRETTY_NAME" | cut -d'"' -f2)"
   echo "内核版本: $(uname -r)"
   echo "OpenSSL版本: $(openssl version)"
   if command -v nginx >/dev/null 2>&1; then
       echo "Nginx版本: $(nginx -v 2>&1)"
   else
       echo "Nginx: 未安装"
   fi
   echo "防火墙状态: $(ufw status | grep Status)"
   
   # 检查常见问题并显示诊断建议
   echo -e "\n诊断建议："
   local problems=0
   
   # 检查域名解析
   if [ -n "$domain" ]; then
       local domain_ip=$(dig +short ${domain})
       local server_ip=$(curl -s ifconfig.me)
       if [ "$domain_ip" != "$server_ip" ]; then
           echo "- 域名解析IP(${domain_ip})与服务器IP(${server_ip})不匹配"
           problems=1
       fi
   fi
   
   # 检查80端口
   if ss -tuln | grep -q ':80 '; then
       echo "- 80端口被占用，可能影响证书申请"
       problems=1
   fi
   
   # 检查日志中的错误
   for log_file in "${log_files[@]}"; do
       if [ -f "$(eval echo $log_file)" ]; then
           if grep -q "error" "$(eval echo $log_file)"; then
               echo "- 日志中发现错误:"
               if grep -q "Verify error" "$(eval echo $log_file)"; then
                   echo "  * 域名验证失败，请检查域名解析是否正确"
                   problems=1
               fi
               if grep -q "connection refused" "$(eval echo $log_file)"; then
                   echo "  * 连接被拒绝，请检查防火墙设置"
                   problems=1
               fi
               if grep -q "timeout" "$(eval echo $log_file)"; then
                   echo "  * 连接超时，可能是网络问题"
                   problems=1
               fi
           fi
       fi
   done
   
   if [ $problems -eq 0 ]; then
       echo "未发现明显问题"
   fi
   
   echo "==================================================="
   echo "提示："
   echo "1. 如需重新申请证书，请选择'申请SSL证书'选项"
   echo "2. 确保域名已正确解析到服务器IP"
   echo "3. 确保80端口未被占用"
   echo "4. 如遇问题可尝试先卸载再重新安装"
}

# 主函数
main() {
    # 检查root权限
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}错误：请使用 root 用户运行此脚本${PLAIN}"
        exit 1
    fi

    # 检查系统
    if ! grep -qi "debian" /etc/os-release; then
        echo -e "${RED}错误：此脚本仅支持 Debian 系统${PLAIN}"
        exit 1
    fi

    # 初始化
    init_status_file
    
    # 主循环
    while true; do
        show_menu
        read -p "请选择操作[0-12]: " choice
        case "${choice}" in
            0) exit 0 ;;
            1) check_reinstall "系统环境" "SYSTEM_PREPARED" && prepare_system ;;
            2) check_reinstall "伪装站点" "NGINX_INSTALLED" && configure_nginx ;;
            3) check_reinstall "SSL证书" "CERT_INSTALLED" && install_cert ;;
            4) view_cert_log ;;
            5) check_reinstall "HAProxy" "HAPROXY_INSTALLED" && install_haproxy ;;
            6) check_reinstall "端口转发" "MULTI_PORT_CONFIGURED" && configure_relay ;;
            7) check_reinstall "UFW防火墙" "UFW_CONFIGURED" && configure_ufw ;;
            8) check_reinstall "BBR加速" "BBR_INSTALLED" && install_bbr ;;
            9) show_config ;;
            10) show_status ;;
            11) restart_services ;;
            12) uninstall_all ;;
            *) log "ERROR" "无效的选择" ;;
        esac
        echo
        read -p "按回车键继续..." </dev/tty
    done
}

# 启动脚本
main "$@"