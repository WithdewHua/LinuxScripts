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

# ── root 检查 ─────────────────────────────────────────────────────────────
if [[ "$(id -u)" -ne 0 ]]; then
  OUT_ERROR "[错误] 本脚本需要 root 权限运行！"
  exit 1
fi

# ── 发行版检测 ────────────────────────────────────────────────────────────
# 本脚本仅支持 Debian 系（使用 apt），CentOS/RHEL 未适配
if grep -q -E -i "debian|raspbian" /etc/issue 2>/dev/null ||
  grep -q -E -i "raspbian|debian" /proc/version 2>/dev/null; then
  release="debian"
elif grep -q -E -i "ubuntu" /etc/issue 2>/dev/null ||
  grep -q -E -i "ubuntu" /proc/version 2>/dev/null; then
  release="ubuntu"
else
  OUT_ERROR "[错误] 不支持的操作系统！本脚本仅支持 Debian / Ubuntu。"
  exit 1
fi

OUT_ALERT "[信息] 优化性能中！"

# ── 安装 haveged ──────────────────────────────────────────────────────────
# 补充熵源，改善随机数生成器性能。
# 内核 5.6+ 起 CRNG 快速初始化、getrandom() 不再阻塞，haveged 已无必要，
# 故仅在旧内核（< 5.6）上安装。haveged 与 rng-tools 二选一，避免同时运行互抢。
kver=$(uname -r | grep -oE '^[0-9]+\.[0-9]+')
kmaj=${kver%%.*}
kmin=${kver#*.}
if [ "$kmaj" -lt 5 ] || { [ "$kmaj" -eq 5 ] && [ "$kmin" -lt 6 ]; }; then
  if [[ -z "$(command -v haveged)" ]]; then
    OUT_INFO "内核 ${kver} < 5.6，安装 haveged 改善随机数生成器性能"
    apt update
    apt install haveged -y
    systemctl enable --now haveged
  fi
else
  OUT_INFO "内核 ${kver} >= 5.6，无需 haveged，跳过"
fi

# ── 禁用 ksmtuned ─────────────────────────────────────────────────────────
if [[ ! -z "$(command -v ksmtuned)" ]]; then
  OUT_INFO "禁用 ksmtuned"
  echo 2 >/sys/kernel/mm/ksm/run
  apt purge ksmtuned --autoremove -y || true
  rm -rf /etc/systemd/system/ksmtuned.service
  mv /usr/sbin/ksmtuned /usr/sbin/ksmtuned.bak || true
  touch /usr/sbin/ksmtuned
  echo "# KSMTUNED DISABLED" >/usr/sbin/ksmtuned
fi

# ── 禁用 hugepage ─────────────────────────────────────────────────────────
OUT_INFO "禁用 hugepage"
cat >/etc/systemd/system/disable-transparent-huge-pages.service <<EOF
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
OUT_INFO "启用 tls、nf_conntrack、tcp_bbr 内核模块"
echo nf_conntrack >/etc/modules-load.d/withdewhua-network-optimized.conf
echo tls >>/etc/modules-load.d/withdewhua-network-optimized.conf
echo tcp_bbr >>/etc/modules-load.d/withdewhua-network-optimized.conf

# ── 立即加载模块 ──────────────────────────────────────────────────────────
# 加载 tls；nf_conntrack 待其 hashsize 计算完成后再加载（见下方内存计算段）。
modprobe tls 2>/dev/null || true

# ── BBR 可用性检查 ────────────────────────────────────────────────────────
# 尝试加载 tcp_bbr；若内核不支持则回退到 cubic，避免 sysctl 设置失败后无拥塞控制生效。
modprobe tcp_bbr 2>/dev/null || true
if sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
  tcp_cc=bbr
  OUT_INFO "BBR 可用，使用 bbr 拥塞控制"
else
  tcp_cc=cubic
  OUT_ALERT "[警告] 当前内核不支持 BBR，回退到 cubic（建议升级内核）"
fi

# ══════════════════════════════════════════════════════════════════════════
# 动态计算内存相关参数
# ══════════════════════════════════════════════════════════════════════════
OUT_INFO "计算内存相关参数"

mems=$(free --bytes | grep Mem | awk '{print $2}')
page=$(getconf PAGESIZE)
total_pages=$((mems / page))
mems_mb=$((mems / 1024 / 1024))

OUT_INFO "检测到内存: ${mems_mb}MB，页大小: ${page}B，总页数: ${total_pages}"

# ── fs.file-max（系统级文件句柄上限）─────────────────────────────────────
# file-max 的真正约束是内核内存（每个句柄约 1KB），而非单进程 nofile。
# 故按内存动态计算：允许最坏情况下文件句柄最多占用约 50% RAM。
#   file-max = 内存字节 / 2048  （= (mems * 0.5) / 1024）
# 设 256k 下限，防止极小内存机算出过低的值。
fs_file_max=$((mems / 2048))
[ "$fs_file_max" -lt 262144 ] && fs_file_max=262144
OUT_INFO "fs.file-max = ${fs_file_max}"

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
  tcp_mem_min=$((total_pages * 8 / 100))
  tcp_mem_pressure=$((total_pages * 20 / 100))
  tcp_mem_max=$((total_pages * 30 / 100))
elif [ "$mems_mb" -le 2048 ]; then
  tcp_mem_min=$((total_pages * 8 / 100))
  tcp_mem_pressure=$((total_pages * 25 / 100))
  tcp_mem_max=$((total_pages * 40 / 100))
elif [ "$mems_mb" -le 4096 ]; then
  tcp_mem_min=$((total_pages * 8 / 100))
  tcp_mem_pressure=$((total_pages * 30 / 100))
  tcp_mem_max=$((total_pages * 50 / 100))
elif [ "$mems_mb" -le 8192 ]; then
  tcp_mem_min=$((total_pages * 6 / 100))
  tcp_mem_pressure=$((total_pages * 30 / 100))
  tcp_mem_max=$((total_pages * 50 / 100))
elif [ "$mems_mb" -le 16384 ]; then
  tcp_mem_min=$((total_pages * 6 / 100))
  tcp_mem_pressure=$((total_pages * 30 / 100))
  tcp_mem_max=$((total_pages * 50 / 100))
else
  tcp_mem_min=$((total_pages * 5 / 100))
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

tcp_mem_max_bytes=$((tcp_mem_max * page))
buf_max=$((tcp_mem_max_bytes / 64))

# 分档下限（激进）
if [ "$mems_mb" -le 1024 ]; then
  buf_floor=$((32 * 1024 * 1024)) # 32MB
elif [ "$mems_mb" -le 2048 ]; then
  buf_floor=$((64 * 1024 * 1024)) # 64MB
elif [ "$mems_mb" -le 4096 ]; then
  buf_floor=$((128 * 1024 * 1024)) # 128MB
elif [ "$mems_mb" -le 8192 ]; then
  buf_floor=$((256 * 1024 * 1024)) # 256MB
else
  buf_floor=$((512 * 1024 * 1024)) # 512MB
fi

[ "$buf_max" -lt "$buf_floor" ] && buf_max=$buf_floor

# default 值统一设为 256KB（收发对称）
buf_default=$((256 * 1024)) # 256KB

# tcp_rmem / tcp_wmem 的 min 值保持内核惯例
tcp_rmem_min=8192 # 8KB
tcp_wmem_min=4096 # 4KB

buf_max_mb=$((buf_max / 1024 / 1024))
OUT_INFO "rmem/wmem max = ${buf_max_mb}MB，default = $((buf_default / 1024))KB"

# ── udp_mem（单位：页）────────────────────────────────────────────────────
# UDP 型代理（Hysteria2/TUIC/WireGuard）需要独立的 UDP 内存池，与 tcp_mem 同档处理。
udp_mem_min=$tcp_mem_min
udp_mem_pressure=$tcp_mem_pressure
udp_mem_max=$tcp_mem_max
OUT_INFO "udp_mem = ${udp_mem_min} ${udp_mem_pressure} ${udp_mem_max}"

# ── nf_conntrack_max（条目数）─────────────────────────────────────────────
# 每条目约 300B，固定 1048576 在小内存机上满载可占 300MB+，故按内存伸缩：
#   上限 = 内存字节 / 4096  （最坏约占 ~7.5% RAM）
#   下限 65536，上限 1048576（够用即可，无需无限膨胀）
ct_max=$((mems / 4096))
[ "$ct_max" -lt 65536 ] && ct_max=65536
[ "$ct_max" -gt 1048576 ] && ct_max=1048576
# hashsize 取 conntrack_max 的 1/4 为宜
ct_hashsize=$((ct_max / 4))
OUT_INFO "nf_conntrack_max = ${ct_max}，hashsize = ${ct_hashsize}"

# 写入 hashsize（模块参数）并加载 nf_conntrack，使 net.netfilter.* 可被 sysctl 设置。
# 注：若模块此前已加载，hashsize 需重启后才会按新值生效。
mkdir -p /etc/modprobe.d
echo "options nf_conntrack hashsize=${ct_hashsize}" >/etc/modprobe.d/nf_conntrack.conf
modprobe nf_conntrack 2>/dev/null || true

# ══════════════════════════════════════════════════════════════════════════
# 写入 sysctl 配置
# ══════════════════════════════════════════════════════════════════════════
OUT_INFO "优化参数中！"

SYSCTL_CONF=/etc/sysctl.d/99-z-withdewhua-optimized.conf

cat >"$SYSCTL_CONF" <<EOF
kernel.panic = 1
kernel.task_delayacct = 0
# 内核安全硬化
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
# 系统级文件句柄上限（按内存动态计算）
fs.file-max = ${fs_file_max}
# 单进程可打开文件数硬顶，需 >= limits 中的 nofile，二者取齐为 1048576
fs.nr_open = 1048576
# increase the maximum length of processor input queues
net.core.netdev_max_backlog = 32768
# 提高单次软中断收包预算，降低高 pps 转发时的丢包（默认 300 / 2000）
net.core.netdev_budget = 600
net.core.netdev_budget_usecs = 8000
# fq is recommended for BBR
net.core.default_qdisc = fq
net.core.somaxconn = 32768
# socket 收发缓冲（default 固定 256KB，max 按内存动态计算）
net.core.rmem_default = ${buf_default}
net.core.rmem_max = ${buf_max}
net.core.wmem_default = ${buf_default}
net.core.wmem_max = ${buf_max}
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
# disable redirects for forwarding nodes
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
# 拒绝源路由报文（安全硬化）
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0
# 忽略 ICMP 广播，防 smurf 放大
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.ip_default_ttl = 128
net.ipv4.ip_forward = 1
net.ipv4.ip_local_port_range = 10240 65535
net.ipv4.tcp_abort_on_overflow = 0
net.ipv4.tcp_adv_win_scale = -2
net.ipv4.tcp_autocorking = 1
net.ipv4.tcp_base_mss = 1024
# 拥塞控制（bbr 可用则 bbr，否则回退 cubic）
net.ipv4.tcp_congestion_control = ${tcp_cc}
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
# TCP 内存池（页）与单连接收发缓冲（字节：min default max），均按内存动态计算
net.ipv4.tcp_mem = ${tcp_mem_min} ${tcp_mem_pressure} ${tcp_mem_max}
net.ipv4.tcp_rmem = ${tcp_rmem_min} ${buf_default} ${buf_max}
net.ipv4.tcp_wmem = ${tcp_wmem_min} ${buf_default} ${buf_max}
net.ipv4.tcp_sack = 1
net.ipv4.tcp_syn_retries = 3
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_notsent_lowat = 131072
# UDP 内存池（页），供 UDP 型代理使用，按内存动态计算
net.ipv4.udp_mem = ${udp_mem_min} ${udp_mem_pressure} ${udp_mem_max}
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192
net.ipv4.route.flush = 1
net.ipv6.conf.all.forwarding = 1
net.ipv6.conf.default.forwarding = 1
# 开启 forwarding 后内核默认不再接受 RA，会导致 SLAAC/默认路由丢失、IPv6 掉线；
# 设为 2 表示即使在转发模式下仍接受路由通告。
net.ipv6.conf.all.accept_ra = 2
net.ipv6.conf.default.accept_ra = 2
net.netfilter.nf_conntrack_generic_timeout = 10
net.netfilter.nf_conntrack_gre_timeout = 10
net.netfilter.nf_conntrack_gre_timeout_stream = 60
net.netfilter.nf_conntrack_icmp_timeout = 5
net.netfilter.nf_conntrack_icmpv6_timeout = 5
# conntrack 表上限（按内存动态伸缩），hashsize 见 /etc/modprobe.d/nf_conntrack.conf
net.netfilter.nf_conntrack_max = ${ct_max}
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

OUT_INFO "sysctl 配置已写入 $SYSCTL_CONF"
OUT_INFO "当前动态参数摘要："
OUT_INFO "  fs.file-max      = ${fs_file_max}"
OUT_INFO "  tcp_mem          = ${tcp_mem_min} ${tcp_mem_pressure} ${tcp_mem_max} (pages)"
OUT_INFO "  udp_mem          = ${udp_mem_min} ${udp_mem_pressure} ${udp_mem_max} (pages)"
OUT_INFO "  buf_default      = $((buf_default / 1024))KB"
OUT_INFO "  buf_max          = ${buf_max_mb}MB"
OUT_INFO "  nf_conntrack_max = ${ct_max}（hashsize ${ct_hashsize}）"
OUT_INFO "  拥塞控制         = ${tcp_cc}"

sysctl --system

# ── 解除 nofile nproc 限制 ────────────────────────────────────────────────
OUT_INFO "调整 nofile / nproc 限制"

# 注意：nofile 不能设为 "unlimited"！它受 fs.nr_open 上限约束，
#       部分 PAM/systemd 版本会拒绝 unlimited 从而导致无法登录（sshd 拒绝会话）。
#       nofile 与 nproc 均使用具体数值，避免 unlimited 在部分环境下被拒绝。
cat <<'EOF' >/etc/security/limits.d/99-withdewhua.conf
* soft nofile 1048576
* hard nofile 1048576
* soft nproc 1048576
* hard nproc 1048576
root soft nofile 1048576
root hard nofile 1048576
root soft nproc unlimited
root hard nproc unlimited
EOF

mkdir -p /etc/systemd/system.conf.d
cat <<'EOF' >/etc/systemd/system.conf.d/99-withdewhua.conf
[Manager]
DefaultCPUAccounting=yes
DefaultIOAccounting=yes
DefaultIPAccounting=yes
DefaultMemoryAccounting=yes
DefaultTasksAccounting=yes
DefaultLimitCORE=infinity
DefaultLimitNPROC=infinity
DefaultLimitNOFILE=1048576
EOF

# system.conf 改动需重新执行 systemd 管理进程才会生效
systemctl daemon-reexec

# ── journald ──────────────────────────────────────────────────────────────
OUT_INFO "调整 journald"

mkdir -p /etc/systemd/journald.conf.d
cat >/etc/systemd/journald.conf.d/99-withdewhua.conf <<EOF
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
systemctl restart systemd-journald

OUT_INFO "[信息] 优化完毕！"
exit 0
