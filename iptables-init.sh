#!/bin/bash

# ================================
# IPv4 规则 (iptables)
# ================================

# 清空现有规则
iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -X

# 设置默认策略（拒绝所有）
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT ACCEPT

# 允许本地回环接口
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# 允许已建立的连接
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# 允许 ping (ICMP)
iptables -A INPUT -p icmp --icmp-type echo-request -j ACCEPT

# 允许 SSH (22端口)
iptables -A INPUT -p tcp --dport 22 -j ACCEPT

# 允许 HTTP (80端口)
iptables -A INPUT -p tcp --dport 80 -j ACCEPT

# 允许 HTTPS (443端口)
iptables -A INPUT -p tcp --dport 443 -j ACCEPT
iptables -A INPUT -p udp --dport 443 -j ACCEPT

# ================================
# IPv6 规则 (ip6tables)
# ================================

# 清空现有 IPv6 规则
ip6tables -F
ip6tables -X
ip6tables -t mangle -F
ip6tables -t mangle -X

# 设置默认策略（拒绝所有）
ip6tables -P INPUT DROP
ip6tables -P FORWARD DROP
ip6tables -P OUTPUT ACCEPT

# 允许本地回环接口
ip6tables -A INPUT -i lo -j ACCEPT
ip6tables -A OUTPUT -o lo -j ACCEPT

# 允许已建立的连接
ip6tables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# IPv6 必需的 ICMPv6 消息
ip6tables -A INPUT -p icmpv6 --icmpv6-type destination-unreachable -j ACCEPT
ip6tables -A INPUT -p icmpv6 --icmpv6-type packet-too-big -j ACCEPT
ip6tables -A INPUT -p icmpv6 --icmpv6-type time-exceeded -j ACCEPT
ip6tables -A INPUT -p icmpv6 --icmpv6-type parameter-problem -j ACCEPT

# IPv6 邻居发现协议 (NDP)
ip6tables -A INPUT -p icmpv6 --icmpv6-type router-solicitation -j ACCEPT
ip6tables -A INPUT -p icmpv6 --icmpv6-type router-advertisement -j ACCEPT
ip6tables -A INPUT -p icmpv6 --icmpv6-type neighbor-solicitation -j ACCEPT
ip6tables -A INPUT -p icmpv6 --icmpv6-type neighbor-advertisement -j ACCEPT

# 允许 ping6 (ICMPv6 echo)
ip6tables -A INPUT -p icmpv6 --icmpv6-type echo-request -j ACCEPT

# 允许 SSH (22端口)
ip6tables -A INPUT -p tcp --dport 22 -j ACCEPT

# 允许 HTTP (80端口)
ip6tables -A INPUT -p tcp --dport 80 -j ACCEPT

# 允许 HTTPS (443端口) TCP
ip6tables -A INPUT -p tcp --dport 443 -j ACCEPT

# 允许 HTTPS (443端口) UDP (HTTP/3 QUIC)
ip6tables -A INPUT -p udp --dport 443 -j ACCEPT

# ================================
# 保存规则
# ================================

# Ubuntu/Debian:
# iptables-save > /etc/iptables/rules.v4
# ip6tables-save > /etc/iptables/rules.v6

# CentOS/RHEL:
# service iptables save
# service ip6tables save

# 或者使用 iptables-persistent
# apt-get install iptables-persistent
# netfilter-persistent save

echo "iptables 和 ip6tables 规则配置完成"
echo "IPv4 规则："
iptables -L -n
echo ""
echo "IPv6 规则："
ip6tables -L -n
