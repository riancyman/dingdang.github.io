#!/bin/bash

#########################################################################
# 名称: Linux防火墙管理脚本
# 版本: v1.1.7
# 作者: 叮当的老爷
# 最后更新: 2024-12-03
#########################################################################

# 功能说明:
# 1. 自动检测并显示当前Linux系统版本
# 2. 支持管理多种防火墙(UFW/IPTables/Firewalld)
# 3. 提供完整的防火墙管理功能:
#    - 检查防火墙状态
#    - 安装/重装防火墙
#    - 配置防火墙端口
#    - 设置防火墙自启动
#    - 重启防火墙服务
#    - 卸载防火墙
#    - 系统诊断信息
#########################################################################

# 使用方法:
# 1. 远程调用(推荐):
#    curl方式:
#    curl -sSL https://riancyman.github.io/batscripts/serverbat/ckfirewall.sh -o ckfirewall.sh && sudo bash ckfirewall.sh
#    
#    wget方式:
#    wget -qO ckfirewall.sh https://riancyman.github.io/batscripts/serverbat/ckfirewall.sh && sudo bash ckfirewall.sh
#
# 注意事项:
# 1. 需要root权限执行
# 2. 支持Debian和RedHat系列系统
# 3. 建议在使用前备份现有防火墙配置
#########################################################################

# 设置颜色变量
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color
BLUE='\033[0;34m'

# 定义版本号
VERSION="v1.1.7"

# 检查是否为root用户
check_root() {
    if [ "$(id -u)" != "0" ]; then
        echo -e "${RED}错误: 此脚本需要root权限运行${NC}"
        exit 1
    fi
}

# 检查防火墙状态
check_firewall_status() {
    local ufw_active=false
    local firewalld_active=false
    local iptables_active=false
    local current_firewall=""

    echo -e "\n${YELLOW}防火墙状态检查:${NC}"

    # 检查 UFW
    if command -v ufw >/dev/null 2>&1; then
        if systemctl is-active ufw >/dev/null 2>&1 || ufw status 2>/dev/null | grep -q "Status: active"; then
            ufw_active=true
            current_firewall="UFW"
            echo -e "${GREEN}UFW 状态: 正在运行${NC}"
            echo -e "\n${BLUE}UFW 开放的端口:${NC}"
            ufw status numbered | grep -E "^[[[:space:]]*[0-9]" | sed 's/\[//g;s/\]//g' | while read -r line; do
                port=$(echo "$line" | grep -oE '[0-9]+/(tcp|udp)')
                if [ -n "$port" ]; then
                    echo -e "${GREEN}端口 $port${NC}"
                fi
            done
        else
            echo -e "${YELLOW}UFW 状态: 已安装但未运行${NC}"
        fi
    else
        echo -e "${BLUE}UFW 状态: 未安装${NC}"
    fi

    # 检查 Firewalld
    if command -v firewall-cmd >/dev/null 2>&1; then
        if systemctl is-active firewalld >/dev/null 2>&1; then
            firewalld_active=true
            current_firewall="Firewalld"
            echo -e "${GREEN}Firewalld 状态: 正在运行${NC}"
            echo -e "\n${BLUE}Firewalld 开放的端口:${NC}"
            echo -e "${GREEN}TCP端口:${NC}"
            firewall-cmd --list-ports 2>/dev/null | tr ' ' '\n' | grep "tcp" | while read -r port; do
                echo -e "端口 $port"
            done
            echo -e "${GREEN}UDP端口:${NC}"
            firewall-cmd --list-ports 2>/dev/null | tr ' ' '\n' | grep "udp" | while read -r port; do
                echo -e "端口 $port"
            done
        else
            echo -e "${YELLOW}Firewalld 状态: 已安装但未运行${NC}"
        fi
    else
        echo -e "${BLUE}Firewalld 状态: 未安装${NC}"
    fi

    # 检查 IPTables
    if command -v iptables >/dev/null 2>&1; then
        if iptables -L >/dev/null 2>&1; then
            if ! $ufw_active && ! iptables -L 2>/dev/null | grep -q "Chain .* (policy ACCEPT)"; then
                iptables_active=true
                [ -z "$current_firewall" ] && current_firewall="IPTables"
                echo -e "${GREEN}IPTables 状态: 正在运行${NC}"
                echo -e "\n${BLUE}IPTables 开放的端口:${NC}"
                echo -e "${GREEN}TCP端口:${NC}"
                iptables -L INPUT -n -v | grep -E "^[[:space:]]*[0-9]+" | grep "tcp dpt:" | sed -E 's/.*dpt:([0-9]+).*/\1/' | sort -n | uniq | while read -r port; do
                    echo -e "端口 $port/tcp"
                done
                echo -e "${GREEN}UDP端口:${NC}"
                iptables -L INPUT -n -v | grep -E "^[[:space:]]*[0-9]+" | grep "udp dpt:" | sed -E 's/.*dpt:([0-9]+).*/\1/' | sort -n | uniq | while read -r port; do
                    echo -e "端口 $port/udp"
                done
            elif $ufw_active; then
                echo -e "${BLUE}IPTables 状态: 作为 UFW 的后端运行${NC}"
            else
                echo -e "${YELLOW}IPTables 状态: 已安装但未配置规则${NC}"
            fi
        else
            echo -e "${RED}IPTables 状态: 无法访问${NC}"
        fi
    else
        echo -e "${BLUE}IPTables 状态: 未安装${NC}"
    fi

    # 总结
    if [ -n "$current_firewall" ]; then
        echo -e "\n${GREEN}当前主要防火墙: $current_firewall${NC}"
    else
        echo -e "\n${RED}当前没有防火墙在运行${NC}"
    fi
}

# 获取已安装的防火墙类型
get_installed_firewall() {
    # 检查 UFW
    if [ -f /etc/debian_version ] && dpkg -l | grep -q "^ii.*ufw" && systemctl is-active --quiet ufw; then
        echo "ufw"
        return 0
    elif [ -f /etc/redhat-release ] && rpm -qa | grep -q "ufw" && systemctl is-active --quiet ufw; then
        echo "ufw"
        return 0
    fi
    
    # 检查 Firewalld
    if [ -f /etc/debian_version ] && dpkg -l | grep -q "^ii.*firewalld" && systemctl is-active --quiet firewalld; then
        echo "firewalld"
        return 0
    elif [ -f /etc/redhat-release ] && rpm -qa | grep -q "firewalld" && systemctl is-active --quiet firewalld; then
        echo "firewalld"
        return 0
    fi
    
    # 检查 IPTables
    if [ -f /etc/debian_version ] && dpkg -l | grep -q "^ii.*iptables" && iptables -L -n >/dev/null 2>&1; then
        echo "iptables"
        return 0
    elif [ -f /etc/redhat-release ] && rpm -qa | grep -q "iptables-services" && iptables -L -n >/dev/null 2>&1; then
        echo "iptables"
        return 0
    fi
    
    echo "none"
    return 1
}

# 显示当前开放的端口
show_open_ports() {
    local firewall_type=$1
    echo -e "\n${YELLOW}当前开放的端口:${NC}"
    
    case $firewall_type in
        "iptables")
            echo -e "\n${BLUE}IPTables当前开放的端口:${NC}"
            # 检查 INPUT 链中的所有开放端口
            echo "TCP端口:"
            iptables -L INPUT -n -v | grep -E "^[[:space:]]*[0-9]+" | grep "tcp dpt:" | sed -E 's/.*dpt:([0-9]+).*/\1/' | sort -n | uniq
            echo "UDP端口:"
            iptables -L INPUT -n -v | grep -E "^[[:space:]]*[0-9]+" | grep "udp dpt:" | sed -E 's/.*dpt:([0-9]+).*/\1/' | sort -n | uniq
            
            # 检查 ACCEPT 默认策略
            echo -e "\n防火墙默认策略:"
            local input_policy=$(iptables -L INPUT | head -n1 | awk '{print $4}')
            if [ "$input_policy" = "ACCEPT" ]; then
                echo -e "${GREEN}INPUT链默认策略: ACCEPT (允许所有)${NC}"
            else
                echo -e "${RED}INPUT链默认策略: $input_policy${NC}"
            fi
            
            # 检查网络连接状态
            echo -e "\n当前活动连接:"
            sudo netstat -tunlp4 | grep "LISTEN" | awk '{split($4,a,":"); split($7,b,"/"); 
                if(length(a[2])>0) printf "端口 %-6s: %s\n", a[2], b[2]}' | sort -n -k2
            
            echo -e "\n已建立的连接:"
            sudo netstat -tunp4 | grep "ESTABLISHED" | awk '{split($4,a,":"); 
                if(length(a[2])>0) print a[2]}' | sort -n | uniq | while read port; do
                echo -n "端口 $port: "
                sudo netstat -tunp4 | grep ":$port" | head -1 | awk '{split($7,b,"/"); print b[2]}'
            done
            ;;
        "firewalld")
            echo -e "\n${BLUE}Firewalld当前开放的端口:${NC}"
            firewall-cmd --list-all
            ;;
        "ufw")
            echo -e "\n${BLUE}UFW当前开放的端口:${NC}"
            ufw status verbose
            ;;
    esac
}

# 停止并禁用其他防火墙
disable_other_firewalls() {
    local target_firewall=$1
    echo -e "\n${YELLOW}检查其他防火墙...${NC}"
    
    if [ "$target_firewall" != "ufw" ] && command -v ufw >/dev/null 2>&1; then
        echo -e "${BLUE}停止 UFW...${NC}"
        ufw disable >/dev/null 2>&1
        systemctl stop ufw >/dev/null 2>&1
        systemctl disable ufw >/dev/null 2>&1
    fi
    
    if [ "$target_firewall" != "firewalld" ] && command -v firewall-cmd >/dev/null 2>&1; then
        echo -e "${BLUE}停止 Firewalld...${NC}"
        systemctl stop firewalld >/dev/null 2>&1
        systemctl disable firewalld >/dev/null 2>&1
    fi
    
    if [ "$target_firewall" != "iptables" ] && command -v iptables >/dev/null 2>&1; then
        echo -e "${BLUE}清理 IPTables 规则...${NC}"
        iptables -F >/dev/null 2>&1
        iptables -X >/dev/null 2>&1
        iptables -t nat -F >/dev/null 2>&1
        iptables -t nat -X >/dev/null 2>&1
        iptables -t mangle -F >/dev/null 2>&1
        iptables -t mangle -X >/dev/null 2>&1
        iptables -P INPUT ACCEPT >/dev/null 2>&1
        iptables -P FORWARD ACCEPT >/dev/null 2>&1
        iptables -P OUTPUT ACCEPT >/dev/null 2>&1
        
        if [ -f /etc/debian_version ]; then
            systemctl stop iptables >/dev/null 2>&1
            systemctl disable iptables >/dev/null 2>&1
        elif [ -f /etc/redhat-release ]; then
            systemctl stop iptables >/dev/null 2>&1
            systemctl disable iptables >/dev/null 2>&1
        fi
    fi
    
    echo -e "${GREEN}其他防火墙已停止${NC}"
}

# 安装防火墙
install_firewall() {
    echo -e "\n${YELLOW}可选的防火墙:${NC}"
    echo "1) UFW (推荐)"
    echo "2) Firewalld"
    echo "3) IPTables"
    echo "4) 返回"
    
    read -p "请选择要安装的防火墙 (1-4): " choice
    
    case $choice in
        1)
            if [ -f /etc/debian_version ]; then
                # 先停止其他防火墙
                disable_other_firewalls "ufw"
                
                echo -e "\n${BLUE}安装 UFW...${NC}"
                apt-get update
                apt-get install -y ufw
                
                echo -e "\n${BLUE}配置 UFW...${NC}"
                # 重置所有规则
                ufw --force reset >/dev/null 2>&1
                # 设置默认策略
                ufw default deny incoming >/dev/null 2>&1
                ufw default allow outgoing >/dev/null 2>&1
                # 启用 UFW
                echo "y" | ufw enable >/dev/null 2>&1
                
                if [ $? -eq 0 ]; then
                    echo -e "${GREEN}UFW 安装并启用成功${NC}"
                    echo -e "\n${YELLOW}是否要配置端口? (y/n):${NC}"
                    read -p "" configure_ports
                    if [ "$configure_ports" = "y" ]; then
                        configure_ports
                    fi
                else
                    echo -e "${RED}UFW 安装失败${NC}"
                fi
            elif [ -f /etc/redhat-release ]; then
                # 先停止其他防火墙
                disable_other_firewalls "ufw"
                
                echo -e "\n${BLUE}安装 UFW...${NC}"
                yum install -y ufw
                
                echo -e "\n${BLUE}配置 UFW...${NC}"
                systemctl enable ufw
                systemctl start ufw
                ufw default deny incoming
                ufw default allow outgoing
                ufw enable
                
                if [ $? -eq 0 ]; then
                    echo -e "${GREEN}UFW 安装并启用成功${NC}"
                    echo -e "\n${YELLOW}是否要配置端口? (y/n):${NC}"
                    read -p "" configure_ports
                    if [ "$configure_ports" = "y" ]; then
                        configure_ports
                    fi
                else
                    echo -e "${RED}UFW 安装失败${NC}"
                fi
            fi
            ;;
        2)
            if [ -f /etc/debian_version ]; then
                # 先停止其他防火墙
                disable_other_firewalls "firewalld"
                
                echo -e "\n${BLUE}安装 Firewalld...${NC}"
                apt-get update
                apt-get install -y firewalld
                
                echo -e "\n${BLUE}配置 Firewalld...${NC}"
                systemctl enable firewalld
                systemctl start firewalld
                
                if [ $? -eq 0 ]; then
                    echo -e "${GREEN}Firewalld 安装并启用成功${NC}"
                    echo -e "\n${YELLOW}是否要配置端口? (y/n):${NC}"
                    read -p "" configure_ports
                    if [ "$configure_ports" = "y" ]; then
                        configure_ports
                    fi
                else
                    echo -e "${RED}Firewalld 安装失败${NC}"
                fi
            elif [ -f /etc/redhat-release ]; then
                # 先停止其他防火墙
                disable_other_firewalls "firewalld"
                
                echo -e "\n${BLUE}安装 Firewalld...${NC}"
                yum install -y firewalld
                
                echo -e "\n${BLUE}配置 Firewalld...${NC}"
                systemctl enable firewalld
                systemctl start firewalld
                
                if [ $? -eq 0 ]; then
                    echo -e "${GREEN}Firewalld 安装并启用成功${NC}"
                    echo -e "\n${YELLOW}是否要配置端口? (y/n):${NC}"
                    read -p "" configure_ports
                    if [ "$configure_ports" = "y" ]; then
                        configure_ports
                    fi
                else
                    echo -e "${RED}Firewalld 安装失败${NC}"
                fi
            fi
            ;;
        3)
            if [ -f /etc/debian_version ]; then
                # 先停止其他防火墙
                disable_other_firewalls "iptables"
                
                echo -e "\n${BLUE}安装 IPTables...${NC}"
                apt-get update
                apt-get install -y iptables
                
                echo -e "\n${BLUE}配置 IPTables...${NC}"
                iptables -F
                iptables -X
                iptables -t nat -F
                iptables -t nat -X
                iptables -t mangle -F
                iptables -t mangle -X
                iptables -P INPUT ACCEPT
                iptables -P FORWARD ACCEPT
                iptables -P OUTPUT ACCEPT
                
                if [ $? -eq 0 ]; then
                    echo -e "${GREEN}IPTables 安装并启用成功${NC}"
                    echo -e "\n${YELLOW}是否要配置端口? (y/n):${NC}"
                    read -p "" configure_ports
                    if [ "$configure_ports" = "y" ]; then
                        configure_ports
                    fi
                else
                    echo -e "${RED}IPTables 安装失败${NC}"
                fi
            elif [ -f /etc/redhat-release ]; then
                # 先停止其他防火墙
                disable_other_firewalls "iptables"
                
                echo -e "\n${BLUE}安装 IPTables...${NC}"
                yum install -y iptables-services
                
                echo -e "\n${BLUE}配置 IPTables...${NC}"
                iptables -F
                iptables -X
                iptables -t nat -F
                iptables -t nat -X
                iptables -t mangle -F
                iptables -t mangle -X
                iptables -P INPUT ACCEPT
                iptables -P FORWARD ACCEPT
                iptables -P OUTPUT ACCEPT
                
                if [ $? -eq 0 ]; then
                    echo -e "${GREEN}IPTables 安装并启用成功${NC}"
                    echo -e "\n${YELLOW}是否要配置端口? (y/n):${NC}"
                    read -p "" configure_ports
                    if [ "$configure_ports" = "y" ]; then
                        configure_ports
                    fi
                else
                    echo -e "${RED}IPTables 安装失败${NC}"
                fi
            fi
            ;;
        4)
            return
            ;;
        *)
            echo -e "${RED}无效选择${NC}"
            return
            ;;
    esac
}

# 配置端口
configure_ports() {
    local ports=""
    local current_ports=""
    
    echo -e "\n${YELLOW}当前开放的端口:${NC}"
    
    if command -v ufw >/dev/null 2>&1; then
        # 获取当前开放的端口，只获取端口号，去除其他信息
        current_ports=$(ufw status | grep ALLOW | awk '{print $1}' | cut -d'/' -f1 | sort -n | uniq | tr '\n' ' ')
        if [ -n "$current_ports" ]; then
            echo -e "TCP/UDP端口: ${GREEN}$current_ports${NC}"
        else
            echo -e "${BLUE}当前没有开放的端口${NC}"
        fi
    elif command -v firewall-cmd >/dev/null 2>&1; then
        current_ports=$(firewall-cmd --list-ports 2>/dev/null)
        if [ -n "$current_ports" ]; then
            echo -e "TCP/UDP端口: ${GREEN}$current_ports${NC}"
        else
            echo -e "${BLUE}当前没有开放的端口${NC}"
        fi
    elif command -v iptables >/dev/null 2>&1; then
        current_ports=$(iptables -L INPUT -n | grep ACCEPT | grep -oE "dpt:[0-9]+" | cut -d: -f2 | sort -n | uniq | tr '\n' ' ')
        if [ -n "$current_ports" ]; then
            echo -e "TCP端口: ${GREEN}$current_ports${NC}"
        else
            echo -e "${BLUE}当前没有开放的端口${NC}"
        fi
    fi

    echo -e "\n${YELLOW}请输入要开放的端口（用逗号分隔，例如: 80,443,22）:${NC}"
    read -p "" ports

    if [ -n "$ports" ]; then
        # 移除所有空格
        ports=$(echo "$ports" | tr -d ' ')
        # 使用逗号分隔端口
        IFS=',' read -ra PORT_ARRAY <<< "$ports"
        
        for port in "${PORT_ARRAY[@]}"; do
            # 验证端口号是否有效
            if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
                echo -e "${RED}无效的端口号: $port (端口号必须在 1-65535 之间)${NC}"
                continue
            fi
            
            # 检查端口是否已经开放
            if command -v ufw >/dev/null 2>&1; then
                if ufw status | grep -q "^$port/"; then
                    echo -e "${YELLOW}端口 $port 已经开放${NC}"
                    continue
                fi
                # 添加新端口
                ufw allow "$port/tcp" >/dev/null 2>&1
                ufw allow "$port/udp" >/dev/null 2>&1
                if ufw status | grep -q "^$port/"; then
                    echo -e "${GREEN}端口 $port 已开放 (TCP/UDP)${NC}"
                else
                    echo -e "${RED}端口 $port 开放失败${NC}"
                fi
            elif command -v firewall-cmd >/dev/null 2>&1; then
                if firewall-cmd --query-port="$port/tcp" >/dev/null 2>&1; then
                    echo -e "${YELLOW}端口 $port 已经开放${NC}"
                    continue
                fi
                firewall-cmd --permanent --add-port="$port/tcp" >/dev/null 2>&1
                firewall-cmd --permanent --add-port="$port/udp" >/dev/null 2>&1
                firewall-cmd --reload >/dev/null 2>&1
                if firewall-cmd --query-port="$port/tcp" >/dev/null 2>&1; then
                    echo -e "${GREEN}端口 $port 已开放 (TCP/UDP)${NC}"
                else
                    echo -e "${RED}端口 $port 开放失败${NC}"
                fi
            elif command -v iptables >/dev/null 2>&1; then
                if iptables -L INPUT -n | grep -q "dpt:$port"; then
                    echo -e "${YELLOW}端口 $port 已经开放${NC}"
                    continue
                fi
                iptables -A INPUT -p tcp --dport "$port" -j ACCEPT
                iptables -A INPUT -p udp --dport "$port" -j ACCEPT
                if iptables -L INPUT -n | grep -q "dpt:$port"; then
                    echo -e "${GREEN}端口 $port 已开放 (TCP/UDP)${NC}"
                else
                    echo -e "${RED}端口 $port 开放失败${NC}"
                fi
            fi
        done
        
        # 显示更新后的端口状态
        echo -e "\n${YELLOW}当前开放的端口:${NC}"
        if command -v ufw >/dev/null 2>&1; then
            current_ports=$(ufw status | grep ALLOW | awk '{print $1}' | cut -d'/' -f1 | sort -n | uniq | tr '\n' ' ')
            if [ -n "$current_ports" ]; then
                echo -e "TCP/UDP端口: ${GREEN}$current_ports${NC}"
            fi
        elif command -v firewall-cmd >/dev/null 2>&1; then
            current_ports=$(firewall-cmd --list-ports 2>/dev/null)
            if [ -n "$current_ports" ]; then
                echo -e "TCP/UDP端口: ${GREEN}$current_ports${NC}"
            fi
        elif command -v iptables >/dev/null 2>&1; then
            current_ports=$(iptables -L INPUT -n | grep ACCEPT | grep -oE "dpt:[0-9]+" | cut -d: -f2 | sort -n | uniq | tr '\n' ' ')
            if [ -n "$current_ports" ]; then
                echo -e "TCP端口: ${GREEN}$current_ports${NC}"
            fi
        fi
    else
        echo -e "${YELLOW}未指定端口，跳过端口配置${NC}"
    fi
}

# 配置防火墙自启动
configure_autostart() {
    echo -e "\n${BLUE}配置防火墙自启动...${NC}"
    
    # 检测当前主要使用的防火墙
    local main_firewall=""
    if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
        main_firewall="ufw"
    elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active firewalld >/dev/null 2>&1; then
        main_firewall="firewalld"
    elif command -v iptables >/dev/null 2>&1; then
        main_firewall="iptables"
    fi

    case "$main_firewall" in
        "ufw")
            echo -e "${BLUE}配置 UFW 自启动...${NC}"
            if [ -f /etc/debian_version ]; then
                # 对于 Debian/Ubuntu 系统
                systemctl enable ufw >/dev/null 2>&1
                if [ $? -eq 0 ]; then
                    echo -e "${GREEN}UFW已设置为自启动${NC}"
                    # 确保其他防火墙服务不会自启动
                    systemctl disable netfilter-persistent >/dev/null 2>&1
                    systemctl disable iptables >/dev/null 2>&1
                    systemctl disable firewalld >/dev/null 2>&1
                else
                    echo -e "${RED}UFW自启动设置失败${NC}"
                fi
            elif [ -f /etc/redhat-release ]; then
                # 对于 RedHat/CentOS 系统
                systemctl enable ufw >/dev/null 2>&1
                if [ $? -eq 0 ]; then
                    echo -e "${GREEN}UFW已设置为自启动${NC}"
                    # 确保其他防火墙服务不会自启动
                    systemctl disable iptables >/dev/null 2>&1
                    systemctl disable firewalld >/dev/null 2>&1
                else
                    echo -e "${RED}UFW自启动设置失败${NC}"
                fi
            fi
            ;;
            
        "firewalld")
            echo -e "${BLUE}配置 Firewalld 自启动...${NC}"
            systemctl enable firewalld >/dev/null 2>&1
            if [ $? -eq 0 ]; then
                echo -e "${GREEN}Firewalld已设置为自启动${NC}"
                # 确保其他防火墙服务不会自启动
                systemctl disable ufw >/dev/null 2>&1
                systemctl disable iptables >/dev/null 2>&1
                systemctl disable netfilter-persistent >/dev/null 2>&1
            else
                echo -e "${RED}Firewalld自启动设置失败${NC}"
            fi
            ;;
            
        "iptables")
            echo -e "${BLUE}配置 IPTables 自启动...${NC}"
            if [ -f /etc/debian_version ]; then
                # 对于 Debian/Ubuntu 系统
                apt-get install -y iptables-persistent >/dev/null 2>&1
                systemctl enable netfilter-persistent >/dev/null 2>&1
                if [ $? -eq 0 ]; then
                    echo -e "${GREEN}IPTables已设置为自启动${NC}"
                    # 确保其他防火墙服务不会自启动
                    systemctl disable ufw >/dev/null 2>&1
                    systemctl disable firewalld >/dev/null 2>&1
                else
                    echo -e "${RED}IPTables自启动设置失败${NC}"
                fi
            elif [ -f /etc/redhat-release ]; then
                # 对于 RedHat/CentOS 系统
                systemctl enable iptables >/dev/null 2>&1
                if [ $? -eq 0 ]; then
                    echo -e "${GREEN}IPTables已设置为自启动${NC}"
                    # 确保其他防火墙服务不会自启动
                    systemctl disable ufw >/dev/null 2>&1
                    systemctl disable firewalld >/dev/null 2>&1
                else
                    echo -e "${RED}IPTables自启动设置失败${NC}"
                fi
            fi
            ;;
            
        *)
            echo -e "${RED}错误: 未检测到已安装的防火墙${NC}"
            return 1
            ;;
    esac

    # 验证配置结果
    echo -e "\n${BLUE}验证防火墙自启动状态...${NC}"
    case "$main_firewall" in
        "ufw")
            if systemctl is-enabled ufw >/dev/null 2>&1; then
                echo -e "${GREEN}✓ UFW 已正确配置为自启动${NC}"
            else
                echo -e "${RED}✗ UFW 未正确配置为自启动${NC}"
            fi
            ;;
        "firewalld")
            if systemctl is-enabled firewalld >/dev/null 2>&1; then
                echo -e "${GREEN}✓ Firewalld 已正确配置为自启动${NC}"
            else
                echo -e "${RED}✗ Firewalld 未正确配置为自启动${NC}"
            fi
            ;;
        "iptables")
            if [ -f /etc/debian_version ]; then
                if systemctl is-enabled netfilter-persistent >/dev/null 2>&1; then
                    echo -e "${GREEN}✓ IPTables 已正确配置为自启动${NC}"
                else
                    echo -e "${RED}✗ IPTables 未正确配置为自启动${NC}"
                fi
            elif [ -f /etc/redhat-release ]; then
                if systemctl is-enabled iptables >/dev/null 2>&1; then
                    echo -e "${GREEN}✓ IPTables 已正确配置为自启动${NC}"
                else
                    echo -e "${RED}✗ IPTables 未正确配置为自启动${NC}"
                fi
            fi
            ;;
    esac
}

# 重启防火墙
restart_firewall() {
    echo -e "\n${YELLOW}重启防火墙...${NC}"
    
    # 获取当前活动的防火墙
    local current_firewall=$(get_installed_firewall)
    
    if [ "$current_firewall" = "none" ]; then
        echo -e "${RED}错误: 没有检测到正在运行的防火墙${NC}"
        return 1
    fi
    
    echo -e "${BLUE}正在重启 $current_firewall...${NC}"
    
    # 确保其他防火墙服务已停止
    disable_other_firewalls "$current_firewall"
    
    case "$current_firewall" in
        "ufw")
            # 重启UFW
            if ufw disable && sleep 2 && ufw enable; then
                if ufw status | grep -q "Status: active"; then
                    echo -e "${GREEN}UFW重启成功${NC}"
                    return 0
                fi
            fi
            echo -e "${RED}UFW重启失败${NC}"
            ;;
            
        "firewalld")
            # 重启Firewalld
            if systemctl restart firewalld && sleep 2; then
                if systemctl is-active firewalld >/dev/null 2>&1; then
                    echo -e "${GREEN}Firewalld重启成功${NC}"
                    return 0
                fi
            fi
            echo -e "${RED}Firewalld重启失败${NC}"
            ;;
            
        "iptables")
            # 重启IPTables
            if [ -f /etc/debian_version ]; then
                # 检查是否安装了netfilter-persistent
                if ! dpkg -l | grep -q "^ii.*iptables-persistent"; then
                    echo -e "${YELLOW}正在安装 iptables-persistent...${NC}"
                    DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent >/dev/null 2>&1
                fi
                
                if systemctl is-enabled netfilter-persistent >/dev/null 2>&1; then
                    if systemctl restart netfilter-persistent && sleep 2; then
                        if systemctl is-active netfilter-persistent >/dev/null 2>&1; then
                            echo -e "${GREEN}IPTables重启成功${NC}"
                            return 0
                        fi
                    fi
                else
                    # 如果服务不存在，尝试保存和重新加载规则
                    if iptables-save > /etc/iptables/rules.v4 && \
                       ip6tables-save > /etc/iptables/rules.v6 && \
                       iptables-restore < /etc/iptables/rules.v4 && \
                       ip6tables-restore < /etc/iptables/rules.v6; then
                        echo -e "${GREEN}IPTables规则已重新加载${NC}"
                        return 0
                    fi
                fi
            elif [ -f /etc/redhat-release ]; then
                if systemctl restart iptables && sleep 2; then
                    if systemctl is-active iptables >/dev/null 2>&1; then
                        echo -e "${GREEN}IPTables重启成功${NC}"
                        return 0
                    fi
                fi
            fi
            echo -e "${RED}IPTables重启失败${NC}"
            ;;
    esac
    
    return 1
}

# 卸载防火墙
uninstall_firewall() {
    echo -e "\n${YELLOW}卸载防火墙...${NC}"
    
    local has_changes=false
    
    # UFW卸载
    if command -v ufw >/dev/null 2>&1; then
        echo -e "${BLUE}正在卸载UFW...${NC}"
        ufw disable >/dev/null 2>&1
        if [ -f /etc/debian_version ]; then
            apt-get remove --purge -y ufw >/dev/null 2>&1
            apt-get autoremove -y >/dev/null 2>&1
        elif [ -f /etc/redhat-release ]; then
            yum remove -y ufw >/dev/null 2>&1
        fi
        # 等待UFW完全卸载
        for i in {1..10}; do
            if ! command -v ufw >/dev/null 2>&1; then
                break
            fi
            sleep 1
        done
        has_changes=true
    fi
    
    # Firewalld卸载
    if command -v firewall-cmd >/dev/null 2>&1; then
        echo -e "${BLUE}正在卸载Firewalld...${NC}"
        systemctl stop firewalld >/dev/null 2>&1
        systemctl disable firewalld >/dev/null 2>&1
        if [ -f /etc/debian_version ]; then
            apt-get remove --purge -y firewalld >/dev/null 2>&1
            apt-get autoremove -y >/dev/null 2>&1
        elif [ -f /etc/redhat-release ]; then
            yum remove -y firewalld >/dev/null 2>&1
        fi
        # 等待Firewalld完全卸载
        for i in {1..10}; do
            if ! command -v firewall-cmd >/dev/null 2>&1; then
                break
            fi
            sleep 1
        done
        has_changes=true
    fi
    
    # IPTables卸载
    if command -v iptables >/dev/null 2>&1; then
        echo -e "${BLUE}正在卸载IPTables...${NC}"
        if [ -f /etc/debian_version ]; then
            apt-get remove --purge -y iptables-persistent >/dev/null 2>&1
            apt-get autoremove -y >/dev/null 2>&1
        elif [ -f /etc/redhat-release ]; then
            systemctl stop iptables >/dev/null 2>&1
            systemctl disable iptables >/dev/null 2>&1
            yum remove -y iptables-services >/dev/null 2>&1
        fi
        # 等待IPTables服务完全卸载
        for i in {1..10}; do
            if ! systemctl is-active iptables >/dev/null 2>&1; then
                break
            fi
            sleep 1
        done
        has_changes=true
    fi
    
    if [ "$has_changes" = true ]; then
        echo -e "${GREEN}防火墙卸载完成${NC}"
        # 等待系统完成所有卸载操作
        sleep 3
        return 0
    else
        echo -e "${YELLOW}没有检测到已安装的防火墙${NC}"
        return 1
    fi
}

# 检查诊断信息
check_diagnostic() {
    echo -e "\n${BLUE}系统诊断信息:${NC}"
    
    # 系统信息
    echo -e "\n${YELLOW}系统信息:${NC}"
    uname -a
    
    # 防火墙服务状态
    echo -e "\n${YELLOW}防火墙服务状态:${NC}"
    if command -v ufw >/dev/null 2>&1; then
        echo "UFW状态:"
        systemctl status ufw 2>/dev/null || echo "UFW服务未安装"
    fi
    
    if command -v firewall-cmd >/dev/null 2>&1; then
        echo -e "\nFirewalld状态:"
        systemctl status firewalld 2>/dev/null || echo "Firewalld服务未安装"
    fi
    
    if command -v iptables >/dev/null 2>&1; then
        echo -e "\nIPTables规则:"
        iptables -L -n 2>/dev/null || echo "IPTables未启用或无法访问"
    fi
    
    # 网络连接状态
    echo -e "\n${YELLOW}网络连接状态:${NC}"
    netstat -tunlp 2>/dev/null || ss -tunlp 2>/dev/null || echo "无法获取网络连接信息"
    
    # 已建立的连接
    echo -e "\n${YELLOW}已建立的连接:${NC}"
    netstat -tn 2>/dev/null | grep ESTABLISHED || ss -tn 2>/dev/null | grep ESTAB || echo "无法获取已建立的连接信息"
    
    # 系统日志
    echo -e "\n${YELLOW}系统日志最后20行:${NC}"
    if [ -f /var/log/syslog ]; then
        tail -n 20 /var/log/syslog
    elif [ -f /var/log/messages ]; then
        tail -n 20 /var/log/messages
    else
        # 如果常规日志文件不存在，尝试从journalctl获取
        journalctl -n 20 2>/dev/null || echo "无法访问系统日志"
    fi
    
    # 防火墙相关日志
    echo -e "\n${YELLOW}防火墙相关日志:${NC}"
    if [ -f /var/log/ufw.log ]; then
        echo "UFW日志最后10行:"
        tail -n 10 /var/log/ufw.log
    fi
    
    if [ -f /var/log/firewalld ]; then
        echo -e "\nFirewalld日志最后10行:"
        tail -n 10 /var/log/firewalld
    fi
    
    # 显示系统资源使用情况
    echo -e "\n${YELLOW}系统资源使用情况:${NC}"
    echo "CPU和内存使用:"
    top -b -n 1 | head -n 5
    
    echo -e "\n磁盘使用:"
    df -h
    
    # 检查SELinux状态（如果存在）
    if command -v getenforce >/dev/null 2>&1; then
        echo -e "\n${YELLOW}SELinux状态:${NC}"
        getenforce
    fi
    
    echo -e "\n${GREEN}诊断信息收集完成${NC}"
}

# 显示菜单
show_menu() {
    clear
    echo -e "${BLUE}防火墙管理菜单${NC}"
    echo -e "${YELLOW}当前版本: $VERSION${NC}\n"
    echo "1) 检查防火墙状态"
    echo "2) 重装防火墙"
    echo "3) 配置防火墙端口"
    echo "4) 开启防火墙自动重启"
    echo "5) 重启防火墙"
    echo "6) 卸载防火墙"
    echo "7) 检查诊断信息"
    echo "0) 退出"
    echo ""
    echo -e "请选择操作 (0-7): "
}

# 主菜单循环
main_menu() {
    while true; do
        show_menu
        read -p "" choice
        
        case $choice in
            1) check_firewall_status ;;
            2) install_firewall ;;
            3) configure_ports ;;
            4) configure_autostart ;;
            5) restart_firewall ;;
            6) uninstall_firewall ;;
            7) check_diagnostic ;;
            0) 
                echo -e "\n${GREEN}退出程序${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}无效的选择，请重试${NC}"
                ;;
        esac
        
        echo -e "\n${YELLOW}按回车键继续...${NC}"
        read
    done
}

# 主程序开始
check_root
main_menu