#!/usr/bin/env bash
#
# Description: A Benchmark Script for Linux Server
# Original: https://bench.sh by teddysun
# Forked by: alireza-2030
#
# Copyright (C) 2015 - 2024 Teddysun <i@teddysun.com>
# Thanks: LookBack <admin@dwhd.org>
# URL: https://teddysun.com/444.html
#

trap _exit INT QUIT TERM

_red() {
    printf '\033[0;31;31m%b\033[0m' "$1"
}

_green() {
    printf '\033[0;31;32m%b\033[0m' "$1"
}

_yellow() {
    printf '\033[0;31;33m%b\033[0m' "$1"
}

_blue() {
    printf '\033[0;31;36m%b\033[0m' "$1"
}

_exists() {
    local cmd="$1"
    if eval type type >/dev/null 2>&1; then
        eval type "$cmd" >/dev/null 2>&1
    elif command >/dev/null 2>&1; then
        command -v "$cmd" >/dev/null 2>&1
    else
        which "$cmd" >/dev/null 2>&1
    fi
    local rt=$?
    return ${rt}
}

_exit() {
    _red "\nThe script has been terminated.\n"
    # clean up
    rm -fr speedtest.tgz speedtest-cli benchtest_*
    exit 1
}

get_opsy() {
    [ -f /etc/redhat-release ] && awk '{print $0}' /etc/redhat-release && return
    [ -f /etc/os-release ] && awk -F'[= "]' '/PRETTY_NAME/{print $3,$4,$5}' /etc/os-release && return
    [ -f /etc/lsb-release ] && awk -F'[="]+' '/DESCRIPTION/{print $2}' /etc/lsb-release && return
}

next() {
    printf "%-74s\n" "-" | sed 's/\s/-/g'
}

speed_test() {
    local nodeName="$2"
    [ -z "$1" ] && ./speedtest-cli/speedtest --progress=no --accept-license --accept-gdpr > ./speedtest-cli/speedtest.log 2>&1 || \
    ./speedtest-cli/speedtest --progress=no --server-id="$1" --accept-license --accept-gdpr > ./speedtest-cli/speedtest.log 2>&1
    if [ $? -eq 0 ]; then
        local dl_speed=$(awk '/Download/{print $3" "$4}' ./speedtest-cli/speedtest.log)
        local up_speed=$(awk '/Upload/{print $3" "$4}' ./speedtest-cli/speedtest.log)
        local latency=$(awk '/Idle Latency/{print $3" "$4}' ./speedtest-cli/speedtest.log)
        if [[ -n "${dl_speed}" && -n "${up_speed}" && -n "${latency}" ]]; then
            printf "\033[0;33m%-18s\033[0;32m%-18s\033[0;31m%-20s\033[0;36m%-12s\033[0m\n" " ${nodeName}" "${up_speed}" "${dl_speed}" "${latency}"
        fi
    fi
}

speed() {
    speed_test '' 'Speedtest.net'
    speed_test '21541' 'Los Angeles, US'
    speed_test '43860' 'Dallas, US'
    speed_test '40879' 'Montreal, CA'
    speed_test '24215' 'Paris, FR'
    speed_test '28922' 'Amsterdam, NL'
    speed_test '24447' 'Shanghai, CN'
    speed_test '5530'  'Chongqing, CN'
    speed_test '60572' 'Guangzhou, CN'
    speed_test '32155' 'Hongkong, CN'
    speed_test '23545' 'Mumbai, IN'
    speed_test '13623' 'Singapore, SG'
    speed_test '21569' 'Tokyo, JP'
}

io_test() {
    (LANG=C dd if=/dev/zero of=benchtest_$$ bs=512k count=$1 conv=fdatasync && rm -f benchtest_$$) 2>&1 | awk -F, '{io=$NF} END { print io}' | sed 's/^[ \t]*//;s/[ \t]*$//'
}

calc_size() {
    local raw=$1
    local total_size=0
    local num=1
    local unit="KB"
    if ! [[ ${raw} =~ ^[0-9]+$ ]]; then
        echo ""
        return
    fi
    if [ "${raw}" -ge 1073741824 ]; then
        num=1073741824
        unit="TB"
    elif [ "${raw}" -ge 1048576 ]; then
        num=1048576
        unit="GB"
    elif [ "${raw}" -ge 1024 ]; then
        num=1024
        unit="MB"
    elif [ "${raw}" -eq 0 ]; then
        echo "${total_size}"
        return
    fi
    total_size=$(awk "BEGIN{printf \"%.1f\",${raw}/${num}}")
    echo "${total_size} ${unit}"
}

check_virt() {
    _exists "dmesg" && virtualx="$(dmesg 2>/dev/null)"
    if _exists "systemd-detect-virt"; then
        sys_virt="$(systemd-detect-virt)"
        if [ "${sys_virt}" = "none" ]; then
            virt="Dedicated"
        else
            virt="${sys_virt}"
        fi
    elif [ -f /proc/cpuinfo ]; then
        if grep -qi "kvm" /proc/cpuinfo; then
            virt="KVM"
        elif grep -qi "vmware" /proc/cpuinfo; then
            virt="VMware"
        elif grep -qi "microsoft" /proc/cpuinfo || grep -qi "hyperv" /proc/cpuinfo; then
            virt="Microsoft"
        elif grep -qi "xen" /proc/cpuinfo; then
            virt="Xen"
        fi
    elif [ -n "${virtualx}" ]; then
        if echo "${virtualx}" | grep -qi "virtualbox"; then
            virt="VirtualBox"
        elif echo "${virtualx}" | grep -qi "kvm"; then
            virt="KVM"
        elif echo "${virtualx}" | grep -qi "vmware"; then
            virt="VMware"
        elif echo "${virtualx}" | grep -qi "xen"; then
            virt="Xen"
        fi
    else
        virt="Dedicated"
    fi
}

ipv4_info() {
    local org="$(wget -q -T 10 -O - ipinfo.io/org 2>/dev/null)"
    local city="$(wget -q -T 10 -O - ipinfo.io/city 2>/dev/null)"
    local country="$(wget -q -T 10 -O - ipinfo.io/country 2>/dev/null)"
    local region="$(wget -q -T 10 -O - ipinfo.io/region 2>/dev/null)"
    if [[ -n "$org" ]]; then
        echo " Organization     : $(_blue "$org")"
    fi
    if [[ -n "$city" && -n "$country" ]]; then
        echo " Location         : $(_blue "$city / $country")"
    fi
    if [[ -n "$region" ]]; then
        echo " Region           : $(_blue "$region")"
    fi
}

install_speedtest() {
    if [ ! -e "./speedtest-cli/speedtest" ]; then
        sys_bit=""
        local sysarch="$(uname -m)"
        if [ "${sysarch}" = "unknown" ] || [ "${sysarch}" = "" ]; then
            sysarch="$(arch)"
        fi
        if [ "${sysarch}" = "x86_64" ]; then
            sys_bit="x86_64"
        fi
        if [ "${sysarch}" = "i386" ] || [ "${sysarch}" = "i686" ]; then
            sys_bit="i386"
        fi
        if [ "${sysarch}" = "armv8" ] || [ "${sysarch}" = "armv8l" ] || [ "${sysarch}" = "aarch64" ] || [ "${sysarch}" = "arm64" ]; then
            sys_bit="aarch64"
        fi
        if [ "${sysarch}" = "armv7" ] || [ "${sysarch}" = "armv7l" ]; then
            sys_bit="armhf"
        fi
        if [ "${sysarch}" = "s390x" ]; then
            sys_bit="s390x"
        fi
        if [ -n "${sys_bit}" ]; then
            url1="https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-linux-${sys_bit}.tgz"
            url2="https://dl.lamp.sh/files/ookla-speedtest-1.2.0-linux-${sys_bit}.tgz"
            wget --no-check-certificate -q -T 10 -O speedtest.tgz ${url1}
            if [ $? -ne 0 ]; then
                wget --no-check-certificate -q -T 10 -O speedtest.tgz ${url2}
            fi
            if [ $? -eq 0 ]; then
                mkdir -p speedtest-cli && tar zxf speedtest.tgz -C ./speedtest-cli && chmod +x ./speedtest-cli/speedtest
                rm -f speedtest.tgz
            fi
        else
            _red "Error: Unsupported architecture (${sysarch}).\n"
            exit 1
        fi
    fi
}

print_intro() {
    echo "-------------------- A Bench.sh Script -------------------"
    echo "                     Version: v2024-06-30"
    echo "                 Usage: wget -qO- bench.sh | bash"
    echo "--------------------------------------------------------------"
}

# Get System information
get_system_info() {
    cname=$(awk -F: '/model name/ {name=$2} END {print name}' /proc/cpuinfo | sed 's/^[ \t]*//;s/[ \t]*$//')
    cores=$(awk -F: '/^processor/ {core++} END {print core}' /proc/cpuinfo)
    freq=$(awk -F'[ :]' '/cpu MHz/ {print $4;exit}' /proc/cpuinfo)
    ccache=$(awk -F: '/cache size/ {cache=$2} END {print cache}' /proc/cpuinfo | sed 's/^[ \t]*//;s/[ \t]*$//')
    cpu_aes=$(grep -i 'aes' /proc/cpuinfo)
    cpu_virt=$(grep -Ei 'vmx|svm' /proc/cpuinfo)
    tram=$(free -m | awk '/Mem/ {print $2}')
    uram=$(free -m | awk '/Mem/ {print $3}')
    swap=$(free -m | awk '/Swap/ {print $2}')
    uswap=$(free -m | awk '/Swap/ {print $3}')
    up=$(awk '{a=$1/86400;b=($1%86400)/3600;c=($1%3600)/60} {printf("%d days, %d hour %d min\n",a,b,c)}' /proc/uptime)
    if _exists "w"; then
        load=$(w | head -1 | awk -F'load average:' '{print $2}' | sed 's/^[ \t]*//;s/[ \t]*$//')
    elif _exists "uptime"; then
        load=$(uptime | head -1 | awk -F'load average:' '{print $2}' | sed 's/^[ \t]*//;s/[ \t]*$//')
    fi
    opession=$(get_opsy)
    arch=$(uname -m)
    if _exists "getconf"; then
        lbit=$(getconf LONG_BIT)
    else
        echo ${arch} | grep -q "64" && lbit="64" || lbit="32"
    fi
    kern=$(uname -r)
    disk_size1=$(LANG=C df -hPl | grep -wvE '\-|none|tmpfs|devtmpfs|by-uuid|chroot|Filesystem|udev|docker|snap' | awk '{print $2}')
    disk_size2=$(LANG=C df -hPl | grep -wvE '\-|none|tmpfs|devtmpfs|by-uuid|chroot|Filesystem|udev|docker|snap' | awk '{print $3}')
    tcpctrl=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk -F ' ' '{print $NF}')
}

# Print System information
print_system_info() {
    if [ -n "$cname" ]; then
        echo " CPU Model        : $(_blue "$cname")"
    else
        echo " CPU Model        : $(_blue "CPU model not detected")"
    fi
    if [ -n "$freq" ]; then
        echo " CPU Cores        : $(_blue "$cores @ ${freq} MHz")"
    else
        echo " CPU Cores        : $(_blue "$cores")"
    fi
    if [ -n "$ccache" ]; then
        echo " CPU Cache        : $(_blue "$ccache")"
    fi
    if [ -n "$cpu_aes" ]; then
        echo " AES-NI           : $(_green "Enabled")"
    else
        echo " AES-NI           : $(_red "Disabled")"
    fi
    if [ -n "$cpu_virt" ]; then
        echo " VM-x/AMD-V       : $(_green "Enabled")"
    else
        echo " VM-x/AMD-V       : $(_red "Disabled")"
    fi
    echo " Total Disk       : $(_yellow "$disk_size1") $(_blue "($disk_size2 Used)")"
    echo " Total Mem        : $(_yellow "${tram} MB") $(_blue "(${uram} MB Used)")"
    if [ "$swap" -gt 0 ]; then
        echo " Total Swap       : $(_blue "${swap} MB (${uswap} MB Used)")"
    fi
    echo " System           : $(_blue "$opession")"
    echo " Architecture     : $(_blue "$arch ($lbit Bit)")"
    echo " Kernel           : $(_blue "$kern")"
    if [ -n "$tcpctrl" ]; then
        echo " TCP CC           : $(_yellow "$tcpctrl")"
    fi
    echo " Virtualization   : $(_blue "$virt")"
}

print_io_test() {
    freession=$(df -m . | awk 'NR==2 {print $4}')
    if [ -z "${freession}" ]; then
        freession=$(df -m . | awk 'NR==3 {print $3}')
    fi
    if [ ${freession} -gt 1024 ]; then
        wression=$((freession / 2))
        if [ ${wression} -gt 10240 ]; then
            wression=10240
        fi
        wression_kb=$((wression * 1024))
        wression_count=$((wression_kb / 512))
        echo " I/O Speed(1st run): $(_yellow "$(io_test ${wression_count})")"
        echo " I/O Speed(2nd run): $(_yellow "$(io_test ${wression_count})")"
        echo " I/O Speed(3rd run): $(_yellow "$(io_test ${wression_count})")"
    else
        echo " $(_red "Not enough space for I/O Speed test!")"
    fi
}

print_end_time() {
    end_time=$(date +%s)
    time=$((${end_time} - ${start_time}))
    if [ ${time} -gt 60 ]; then
        min=$((${time} / 60))
        sec=$((${time} % 60))
        echo " Finished in       : ${min} min ${sec} sec"
    else
        echo " Finished in       : ${time} sec"
    fi
    date_time=$(date '+%Y-%m-%d %H:%M:%S %Z')
    echo " Timestamp         : $date_time"
}

! _exists "wget" && _red "Error: wget command not found.\n" && exit 1
! _exists "free" && _red "Error: free command not found.\n" && exit 1
start_time=$(date +%s)

clear
print_intro
next
get_system_info
check_virt
ipv4_info
print_system_info
next
print_io_test
next
install_speedtest

if [ -e "./speedtest-cli/speedtest" ]; then
    printf "%-18s%-18s%-20s%-12s\n" " Node Name" "Upload Speed" "Download Speed" "Latency"
    speed && rm -fr speedtest-cli
else
    _red "Error: Speedtest is not available. Skipping network tests.\n"
fi

next
print_end_time
next
