#!/usr/bin/env bash
# original: https://cdn.skk.moe/sh/optimize.sh
# modified by WithdewHua
# bash <(curl -L -s https://raw.githubusercontent.com/WithdewHua/LinuxScripts/refs/heads/main/optimize.sh)
echo=echo
for cmd in echo /bin/echo; do
    $cmd >/dev/null 2>&1 || continue

    if ! $cmd -e "" | grep -qE '^-e'; then
        echo=$cmd
        break
    fi
done

CSI=$($echo -e "\033[")
CEND="${CSI}0m"
CDGREEN="${CSI}32m"
CRED="${CSI}1;31m"
CGREEN="${CSI}1;32m"
CYELLOW="${CSI}1;33m"
CBLUE="${CSI}1;34m"
CMAGENTA="${CSI}1;35m"
CCYAN="${CSI}1;36m"

OUT_ALERT() {
    echo -e "${CYELLOW}$1${CEND}"
}

OUT_ERROR() {
    echo -e "${CRED}$1${CEND}"
}

OUT_INFO() {
    echo -e "${CCYAN}$1${CEND}"
}

if [[ -f /etc/redhat-release ]]; then
    release="centos"
elif cat /etc/issue | grep -q -E -i "debian|raspbian"; then
    release="debian"
elif cat /etc/issue | grep -q -E -i "ubuntu"; then
    release="ubuntu"
elif cat /etc/issue | grep -q -E -i "centos|red hat|redhat"; then
    release="centos"
elif cat /proc/version | grep -q -E -i "raspbian|debian"; then
    release="debian"
elif cat /proc/version | grep -q -E -i "ubuntu"; then
    release="ubuntu"
elif cat /proc/version | grep -q -E -i "centos|red hat|redhat"; then
    release="centos"
else
    OUT_ERROR "[错误] 不支持的操作系统！"
    exit 1
fi

OUT_ALERT "[信息] 优化性能中！"

# ── 安装 haveged / rng-tools ──────────────────────────────────────────────
if [[ -z "$(command -v haveged)" ]]; then
    OUT_INFO "安装 haveged 改善随机数生成器性能"
    apt install haveged -y
    systemctl enable haveged
fi
if [[ -z "$(command -v rngd)" ]]; then
    OUT_INFO "安装 rng-tools 改善随机数生成器性能"
    apt install rng-tools -y
    systemctl enable rng-tools
fi

# ── 禁用 ksmtuned ─────────────────────────────────────────────────────────
if [[ ! -z "$(command -v ksmtuned)" ]]; then
    OUT_INFO "禁用 ksmtuned"
    echo 2 > /sys/kernel/mm/ksm/run
    apt purge tuned --autoremove -y || true
    apt purge ksmtuned --autoremove -y || true
    rm -rf /etc/systemd/system/ksmtuned.service
    mv /usr/sbin/ksmtuned /usr/sbin/ksmtuned.bak || true
    touch /usr/sbin/ksmtuned
    echo "# KSMTUNED DISABLED" > /usr/sbin/ksmtuned
fi

# ── 禁用 hugepage ─────────────────────────────────────────────────────────
OUT_INFO "禁用 hugepage"
cat > /etc/systemd/system/disable-transparent-huge-pages.service << EOF
[Unit]
Description=Disable Transparent Huge Pages (THP)
DefaultDependencies=no
After=sysinit.target local-fs.target
Before=mongod.service
[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo never | tee /sys/kernel/mm/transparent_hugepage/enabled > /dev/null'
ExecStart=/bin/sh -c 'echo never | tee /sys/kernel/mm/transparent_hugepage/defrag > /dev/null'
[Install]
WantedBy=basic.target
EOF
systemctl daemon-reload
systemctl start disable-transparent-huge-pages
systemctl enable disable-transparent-huge-pages

# ── 内核模块 ──────────────────────────────────────────────────────────────
OUT_INFO "启用 tls 和 nf_conntrack 内核模块"
echo nf_conntrack > /usr/lib/modules-load.d/withdewhua-network-optimized.conf
echo tls >> /usr/lib/modules-load.d/withdewhua-network-optimized.conf

# ── conntrack hashsize ────────────────────────────────────────────────────
OUT_INFO "设置 nf_conntrack hashsize"
mkdir -p /etc/modprobe.d
echo "options nf_conntrack hashsize=1048576" > /etc/modprobe.d/nf_conntrack.conf

# ══════════════════════════════════════════════════════════════════════════
# 动态计算内存相关参数
# ══════════════════════════════════════════════════════════════════════════
OUT_INFO "计算内存相关参数"

mems=$(free --bytes | grep Mem | awk '{print $2}')
page=$(getconf PAGESIZE)
total_pages=$((mems / page))
mems_mb=$((mems / 1024 / 1024))

OUT_INFO "检测到内存: ${mems_mb}MB，页大小: ${page}B，总页数: ${total_pages}"

# ── tcp_mem（单位：页）────────────────────────────────────────────────────
# 激进策略：优先保障带宽，TCP 允许占用更多内存
#
# 三档含义：
#   min      低于此值不限制 TCP 内存分配（自由区）
#   pressure 超过此值内核开始收缩缓冲区（压力区）
#   max      TCP 内存硬上限，超过则丢包（硬顶）
#
# 激进分档（较之前 min/pressure/max 均上调）：
#   <= 1GB  : min=8%  pressure=20%  max=30%  （小内存保留底线，避免 OOM）
#   <= 2GB  : min=8%  pressure=25%  max=40%
#   <= 4GB  : min=8%  pressure=30%  max=50%
#   <= 8GB  : min=6%  pressure=30%  max=50%
#   <= 16GB : min=6%  pressure=30%  max=50%
#   >  16GB : min=5%  pressure=25%  max=40%  （绝对量已很大，比例无需更高）
#
# 说明：max=50% 意味着内存一半可给 TCP，激进但在专用转发节点上合理；
#       pressure 设在 max 的 60% 处，给内核足够的回收缓冲窗口。

if [ "$mems_mb" -le 1024 ]; then
    tcp_mem_min=$((total_pages *  8 / 100))
    tcp_mem_pressure=$((total_pages * 20 / 100))
    tcp_mem_max=$((total_pages * 30 / 100))
elif [ "$mems_mb" -le 2048 ]; then
    tcp_mem_min=$((total_pages *  8 / 100))
    tcp_mem_pressure=$((total_pages * 25 / 100))
    tcp_mem_max=$((total_pages * 40 / 100))
elif [ "$mems_mb" -le 4096 ]; then
    tcp_mem_min=$((total_pages *  8 / 100))
    tcp_mem_pressure=$((total_pages * 30 / 100))
    tcp_mem_max=$((total_pages * 50 / 100))
elif [ "$mems_mb" -le 8192 ]; then
    tcp_mem_min=$((total_pages *  6 / 100))
    tcp_mem_pressure=$((total_pages * 30 / 100))
    tcp_mem_max=$((total_pages * 50 / 100))
elif [ "$mems_mb" -le 16384 ]; then
    tcp_mem_min=$((total_pages *  6 / 100))
    tcp_mem_pressure=$((total_pages * 30 / 100))
    tcp_mem_max=$((total_pages * 50 / 100))
else
    tcp_mem_min=$((total_pages *  5 / 100))
    tcp_mem_pressure=$((total_pages * 25 / 100))
    tcp_mem_max=$((total_pages * 40 / 100))
fi
# 确保不低于内核推荐最小值
[ "$tcp_mem_min" -lt 96 ] && tcp_mem_min=96

OUT_INFO "tcp_mem = ${tcp_mem_min} ${tcp_mem_pressure} ${tcp_mem_max}"

# ── rmem / wmem（单位：字节）──────────────────────────────────────────────
# 激进策略：单连接缓冲上限 = tcp_mem_max 字节数 / 64
#   （保证至少 64 条并发连接各自可达最大缓冲，较激进）
#
# 同时设置分档下限，防止小内存机器因 tcp_mem 总量本身偏小导致 buf_max 过低：
#   <= 1GB  : 下限 32MB
#   <= 2GB  : 下限 64MB
#   <= 4GB  : 下限 128MB
#   <= 8GB  : 下限 256MB
#   >  8GB  : 下限 512MB
#
# 不设硬上限——完全由 tcp_mem_max / 64 决定，让大内存机器充分发挥。

tcp_mem_max_bytes=$(( tcp_mem_max * page ))
buf_max=$(( tcp_mem_max_bytes / 64 ))

# 分档下限（激进）
if [ "$mems_mb" -le 1024 ]; then
    buf_floor=$((32  * 1024 * 1024))   # 32MB
elif [ "$mems_mb" -le 2048 ]; then
    buf_floor=$((64  * 1024 * 1024))   # 64MB
elif [ "$mems_mb" -le 4096 ]; then
    buf_floor=$((128 * 1024 * 1024))   # 128MB
elif [ "$mems_mb" -le 8192 ]; then
    buf_floor=$((256 * 1024 * 1024))   # 256MB
else
    buf_floor=$((512 * 1024 * 1024))   # 512MB
fi

[ "$buf_max" -lt "$buf_floor" ] && buf_max=$buf_floor

# default 值统一设为 256KB（收发对称）
buf_default=$((256 * 1024))   # 256KB

# tcp_rmem / tcp_wmem 的 min 值保持内核惯例
tcp_rmem_min=8192    # 8KB
tcp_wmem_min=4096    # 4KB

buf_max_mb=$(( buf_max / 1024 / 1024 ))
OUT_INFO "rmem/wmem max = ${buf_max_mb}MB，default = $((buf_default / 1024))KB"

# ══════════════════════════════════════════════════════════════════════════
# 写入 sysctl 配置
# ══════════════════════════════════════════════════════════════════════════
OUT_INFO "优化参数中！"

SYSCTL_CONF=/etc/sysctl.d/99-z-withdewhua-optimized.conf

cat > "$SYSCTL_CONF" << EOF
kernel.panic = 1
kernel.task_delayacct = 0
# increase the maximum length of processor input queues
net.core.netdev_max_backlog = 32768
# fq is recommended for BBR
net.core.default_qdisc = fq
net.core.somaxconn = 32768
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
# disable redirects for forwarding nodes
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.ip_default_ttl = 128
net.ipv4.ip_forward = 1
net.ipv4.ip_local_port_range = 10240 65535
net.ipv4.tcp_abort_on_overflow = 0
net.ipv4.tcp_adv_win_scale = -2
net.ipv4.tcp_autocorking = 1
net.ipv4.tcp_base_mss = 1024
net.ipv4.tcp_collapse_max_bytes = 6291456
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_dsack = 1
# ecn=2: negotiate only when peer supports, safer for public-facing nodes
net.ipv4.tcp_ecn = 2
net.ipv4.tcp_fastopen = 1027
net.ipv4.tcp_fastopen_blackhole_timeout_sec = 10
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_frto = 1
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_max_orphans = 8192
net.ipv4.tcp_max_syn_backlog = 16384
net.ipv4.tcp_max_tw_buckets = 262144
net.ipv4.tcp_mtu_probing = 1
# disable saving ssthresh to route cache; use no_metrics_save instead
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_orphan_retries = 8
net.ipv4.tcp_retries1 = 3
net.ipv4.tcp_retries2 = 8
net.ipv4.tcp_rfc1337 = 1
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_syn_retries = 3
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_notsent_lowat = 131072
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192
net.ipv4.route.flush = 1
net.ipv6.conf.all.forwarding = 1
net.ipv6.conf.default.forwarding = 1
net.netfilter.nf_conntrack_generic_timeout = 10
net.netfilter.nf_conntrack_gre_timeout = 10
net.netfilter.nf_conntrack_gre_timeout_stream = 60
net.netfilter.nf_conntrack_icmp_timeout = 5
net.netfilter.nf_conntrack_icmpv6_timeout = 5
net.netfilter.nf_conntrack_max = 1048576
net.netfilter.nf_conntrack_tcp_timeout_close = 5
net.netfilter.nf_conntrack_tcp_timeout_close_wait = 60
net.netfilter.nf_conntrack_tcp_timeout_established = 3600
net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 60
net.netfilter.nf_conntrack_tcp_timeout_last_ack = 5
net.netfilter.nf_conntrack_tcp_timeout_max_retrans = 30
net.netfilter.nf_conntrack_tcp_timeout_syn_recv = 15
net.netfilter.nf_conntrack_tcp_timeout_syn_sent = 30
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 15
net.netfilter.nf_conntrack_tcp_timeout_unacknowledged = 90
net.netfilter.nf_conntrack_udp_timeout = 5
net.netfilter.nf_conntrack_udp_timeout_stream = 180
vm.overcommit_memory = 1
vm.swappiness = 10
EOF

# ── 动态参数追加 ──────────────────────────────────────────────────────────
# tcp_mem（页）
echo "net.ipv4.tcp_mem = ${tcp_mem_min} ${tcp_mem_pressure} ${tcp_mem_max}" \
    >> "$SYSCTL_CONF"

# core rmem/wmem（字节）
echo "net.core.rmem_default = ${buf_default}"  >> "$SYSCTL_CONF"
echo "net.core.rmem_max = ${buf_max}"          >> "$SYSCTL_CONF"
echo "net.core.wmem_default = ${buf_default}"  >> "$SYSCTL_CONF"
echo "net.core.wmem_max = ${buf_max}"          >> "$SYSCTL_CONF"

# tcp_rmem / tcp_wmem（字节：min default max）
echo "net.ipv4.tcp_rmem = ${tcp_rmem_min} ${buf_default} ${buf_max}" \
    >> "$SYSCTL_CONF"
echo "net.ipv4.tcp_wmem = ${tcp_wmem_min} ${buf_default} ${buf_max}" \
    >> "$SYSCTL_CONF"

# 按 key 排序，方便日后 diff
sort -t= -k1,1 "$SYSCTL_CONF" -o "$SYSCTL_CONF"

OUT_INFO "sysctl 配置已写入 $SYSCTL_CONF"
OUT_INFO "当前动态参数摘要："
OUT_INFO "  tcp_mem     = ${tcp_mem_min} ${tcp_mem_pressure} ${tcp_mem_max} (pages)"
OUT_INFO "  buf_default = $((buf_default / 1024))KB"
OUT_INFO "  buf_max     = ${buf_max_mb}MB"

sysctl --system > /dev/null 2>&1

# ── 解除 nofile nproc 限制 ────────────────────────────────────────────────
OUT_INFO "禁用 nofile nproc 限制"

cat <<'EOF' > /etc/security/limits.conf
* soft nofile unlimited
* hard nofile unlimited
* soft nproc unlimited
* hard nproc unlimited
root soft nofile unlimited
root hard nofile unlimited
root soft nproc unlimited
root hard nproc unlimited
EOF

cat <<'EOF' > /etc/systemd/system.conf
[Manager]
DefaultCPUAccounting=yes
DefaultIOAccounting=yes
DefaultIPAccounting=yes
DefaultMemoryAccounting=yes
DefaultTasksAccounting=yes
DefaultLimitCORE=infinity
DefaultLimitNPROC=infinity
DefaultLimitNOFILE=infinity
EOF

# ── journald ──────────────────────────────────────────────────────────────
OUT_INFO "调整 journald"

cat > /etc/systemd/journald.conf <<EOF
[Journal]
SystemMaxUse=384M
SystemMaxFileSize=128M
SystemMaxFiles=3
RuntimeMaxUse=256M
RuntimeMaxFileSize=128M
RuntimeMaxFiles=3
MaxRetentionSec=604800
MaxFileSec=259200
ForwardToSyslog=no
EOF

OUT_INFO "[信息] 优化完毕！"
exit 0
