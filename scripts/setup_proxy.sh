#!/bin/bash
# setup_proxy.sh - 多节点轮询解析与 sing-box 启动
export LC_ALL=C
set -e

export NODE_LINK=${NODE_LINK:-''}

if [ -z "$NODE_LINK" ]; then
  echo "[INFO] 未配置代理，直连模式"
  echo "IS_PROXY=false" >> $GITHUB_ENV
  exit 0
fi

if ! command -v jq &> /dev/null; then
  echo "[ERROR] jq 未安装，正在安装..."
  sudo apt-get update && sudo apt-get install -y jq
fi

command -v curl &>/dev/null && COMMAND="curl -so" || command -v wget &>/dev/null && COMMAND="wget -qO" || { echo "Error: neither curl nor wget found." >&2; exit 1; }

echo "[INFO] 获取 sing-box 最新版本..."
latest_version=$(curl -s "https://api.github.com/repos/SagerNet/sing-box/releases" | jq -r '[.[] | select(.prerelease==false)][0].tag_name | sub("^v"; "")')
if [ -z "$latest_version" ]; then
  echo "[ERROR] 无法获取 sing-box 最新版本，将下载 v1.13.14"
  export latest_version=1.13.14
fi
echo "[INFO] 最新稳定版本: v${latest_version}"

ARCH_RAW=$(uname -m)
case "${ARCH_RAW}" in
    'x86_64' | 'amd64')  ARCH='amd64' ;;
    'x86' | 'i686' | 'i386') ARCH='386' ;;
    'aarch64' | 'arm64') ARCH='arm64' ;;
    'armv7l')  ARCH='armv7' ;;
    's390x')   ARCH='s390x' ;;
    *) echo "不支持的架构: ${ARCH_RAW}"; exit 1 ;;
esac

$COMMAND sing-box-${latest_version}-linux-${ARCH}.tar.gz "https://github.com/SagerNet/sing-box/releases/download/v${latest_version}/sing-box-${latest_version}-linux-${ARCH}.tar.gz"
tar -xzf "sing-box-${latest_version}-linux-${ARCH}.tar.gz"
mv "sing-box-${latest_version}-linux-${ARCH}/sing-box" ./
rm -f "sing-box-${latest_version}-linux-${ARCH}.tar.gz"
rm -rf "sing-box-${latest_version}-linux-${ARCH}"
chmod +x sing-box

# 辅助函数：URL 解码
url_decode() {
  local encoded="$1"
  printf '%b' "$(echo "$encoded" | sed 's/%/\\x/g')"
}

# 将 NODE_LINK 按行拆分为数组
mapfile -t NODE_ARRAY <<< "$NODE_LINK"

total_nodes=${#NODE_ARRAY[@]}
echo "[INFO] 共检测到代理节点配置行，准备轮询测试..."

node_idx=0
for single_node in "${NODE_ARRAY[@]}"; do
  # 清除任何不可见的空格和 \r 回车符，防止解析错位
  single_node=$(echo "$single_node" | tr -d '[:space:]')
  [ -z "$single_node" ] && continue
  
  node_idx=$((node_idx + 1))
  echo "----------------------------------------"
  echo "[INFO] 正在尝试节点 [$node_idx] ..."

  proto=$(echo "$single_node" | cut -d':' -f1)
  content="${single_node#*://}"
  content="${content%%#*}"

  # 重置节点变量
  outbound_type=""
  outbound_server=""
  outbound_port=""
  outbound_uuid=""
  outbound_flow=""
  outbound_transport_type="tcp"
  outbound_path="/"
  outbound_host=""
  outbound_security="none"
  outbound_sni=""
  outbound_fingerprint="chrome"
  outbound_reality_pbk=""
  outbound_reality_sid=""
  outbound_password=""
  outbound_up_mbps=100
  outbound_down_mbps=100
  outbound_obfs_password=""
  outbound_auth=""
  outbound_congestion="bbr"
  outbound_udp_over_stream="true"
  outbound_zerortt="false"
  outbound_username=""
  outbound_password2=""
  outbound_version="5"
  outbound_insecure="false"
  outbound_alpn=""

  case "$proto" in
    vless)
      uuid_host="${content#*://}"
      uuid="${uuid_host%%@*}"
      rest="${uuid_host#*@}"
      if [[ "$rest" == *"?"* ]]; then host_port="${rest%%\?*}"; query="${rest#*\?}"; else host_port="$rest"; query=""; fi
      outbound_server="${host_port%:*}"
      outbound_port="${host_port#*:}"
      outbound_uuid="$uuid"
      outbound_type="vless"
      if [ -n "$query" ]; then
        flow=$(echo "$query" | grep -o 'flow=[^&]*' | cut -d= -f2); [ -n "$flow" ] && outbound_flow="$flow"
        ttype=$(echo "$query" | grep -o 'type=[^&]*' | cut -d= -f2); [ -n "$ttype" ] && outbound_transport_type="$ttype"
        path_raw=$(echo "$query" | grep -o 'path=[^&]*' | cut -d= -f2)
        if [ -n "$path_raw" ]; then path_decoded=$(url_decode "$path_raw"); outbound_path="${path_decoded%%\?*}"; fi
        host=$(echo "$query" | grep -o 'host=[^&]*' | cut -d= -f2); [ -n "$host" ] && outbound_host="$host"
        sec=$(echo "$query" | grep -o 'security=[^&]*' | cut -d= -f2); [ -n "$sec" ] && outbound_security="$sec"
        sni=$(echo "$query" | grep -o 'sni=[^&]*' | cut -d= -f2); [ -n "$sni" ] && outbound_sni="$sni"
        fp=$(echo "$query" | grep -o 'fp=[^&]*' | cut -d= -f2); [ -n "$fp" ] && outbound_fingerprint="$fp"
        pbk=$(echo "$query" | grep -o 'pbk=[^&]*' | cut -d= -f2); [ -n "$pbk" ] && outbound_reality_pbk="$pbk"
        sid=$(echo "$query" | grep -o 'sid=[^&]*' | cut -d= -f2); [ -n "$sid" ] && outbound_reality_sid="$sid"
        ins=$(echo "$query" | grep -o 'insecure=[^&]*' | cut -d= -f2); [ "$ins" = "1" ] || [ "$ins" = "true" ] && outbound_insecure="true"
        alins=$(echo "$query" | grep -o 'allowInsecure=[^&]*' | cut -d= -f2); [ "$alins" = "1" ] || [ "$alins" = "true" ] && outbound_insecure="true"
      fi
      [ -z "$outbound_host" ] && outbound_host="$outbound_server"
      [ -z "$outbound_sni" ] && outbound_sni="$outbound_server"
      ;;

    vmess)
      b64="${content}"
      mod=$(( ${#b64} % 4 ))
      if [ $mod -eq 2 ]; then b64="${b64}=="; elif [ $mod -eq 3 ]; then b64="${b64}="; fi
      decoded=$(echo "$b64" | base64 -d 2>/dev/null || true)
      if [ -z "$decoded" ]; then echo "[WARN] VMess 解码失败，跳过该节点"; continue; fi
      add=$(echo "$decoded" | jq -r '.add // ""')
      port=$(echo "$decoded" | jq -r '.port // 443')
      id=$(echo "$decoded" | jq -r '.id // ""')
      net=$(echo "$decoded" | jq -r '.net // "tcp"')
      tls=$(echo "$decoded" | jq -r '.tls // ""')
      sni=$(echo "$decoded" | jq -r '.sni // ""')
      host=$(echo "$decoded" | jq -r '.host // ""')
      path_raw=$(echo "$decoded" | jq -r '.path // "/"')
      path_decoded=$(url_decode "$path_raw")
      outbound_path="${path_decoded%%\?*}"
      fp=$(echo "$decoded" | jq -r '.fp // "chrome"')
      outbound_type="vmess"
      outbound_server="$add"
      outbound_port="$port"
      outbound_uuid="$id"
      outbound_transport_type="$net"
      outbound_host="${host:-$add}"
      outbound_sni="${sni:-$add}"
      outbound_fingerprint="$fp"
      outbound_security="$tls"
      ;;

    trojan)
      pass_rest="${content#*://}"
      password="${pass_rest%%@*}"
      rest="${pass_rest#*@}"
      if [[ "$rest" == *"?"* ]]; then host_port="${rest%%\?*}"; query="${rest#*\?}"; else host_port="$rest"; query=""; fi
      outbound_server="${host_port%:*}"
      outbound_port="${host_port#*:}"
      outbound_password="$password"
      outbound_type="trojan"
      if [ -n "$query" ]; then
        ttype=$(echo "$query" | grep -o 'type=[^&]*' | cut -d= -f2); [ -n "$ttype" ] && outbound_transport_type="$ttype"
        path_raw=$(echo "$query" | grep -o 'path=[^&]*' | cut -d= -f2)
        if [ -n "$path_raw" ]; then path_decoded=$(url_decode "$path_raw"); outbound_path="${path_decoded%%\?*}"; fi
        host=$(echo "$query" | grep -o 'host=[^&]*' | cut -d= -f2); [ -n "$host" ] && outbound_host="$host"
        sni=$(echo "$query" | grep -o 'sni=[^&]*' | cut -d= -f2); [ -n "$sni" ] && outbound_sni="$sni"
        fp=$(echo "$query" | grep -o 'fp=[^&]*' | cut -d= -f2); [ -n "$fp" ] && outbound_fingerprint="$fp"
        ins=$(echo "$query" | grep -o 'insecure=[^&]*' | cut -d= -f2); [ "$ins" = "1" ] || [ "$ins" = "true" ] && outbound_insecure="true"
        alins=$(echo "$query" | grep -o 'allowInsecure=[^&]*' | cut -d= -f2); [ "$alins" = "1" ] || [ "$alins" = "true" ] && outbound_insecure="true"
      fi
      [ -z "$outbound_host" ] && outbound_host="$outbound_server"
      [ -z "$outbound_sni" ] && outbound_sni="$outbound_server"
      ;;

    hysteria2|hy2)
      if [[ "$content" == *"@"* ]]; then auth="${content%%@*}"; host_port="${content#*@}"; else host_port="$content"; fi
      if [[ "$host_port" == *"?"* ]]; then hp="${host_port%%\?*}"; query="${host_port#*\?}"; else hp="$host_port"; query=""; fi
      hp="${hp%/}"
      outbound_server="${hp%:*}"
      outbound_port="${hp#*:}"
      outbound_type="hysteria2"
      outbound_auth="$auth"
      if [ -n "$query" ]; then
        obfs=$(echo "$query" | grep -o 'obfs=[^&]*' | cut -d= -f2); [ -n "$obfs" ] && outbound_obfs_password="$obfs"
        sni=$(echo "$query" | grep -o 'sni=[^&]*' | cut -d= -f2); [ -n "$sni" ] && outbound_sni="$sni"
        fp=$(echo "$query" | grep -o 'fp=[^&]*' | cut -d= -f2); [ -n "$fp" ] && outbound_fingerprint="$fp"
        ins=$(echo "$query" | grep -o 'insecure=[^&]*' | cut -d= -f2); [ "$ins" = "1" ] || [ "$ins" = "true" ] && outbound_insecure="true"
        alins=$(echo "$query" | grep -o 'allowInsecure=[^&]*' | cut -d= -f2); [ "$alins" = "1" ] || [ "$alins" = "true" ] && outbound_insecure="true"
      fi
      [ -z "$outbound_sni" ] && outbound_sni="$outbound_server"
      ;;

    tuic)
      uuid_pass="${content%%@*}"
      rest="${content#*@}"
      uuid_pass_clean=$(echo "$uuid_pass" | sed 's/%3A/:/g')
      if [[ "$uuid_pass_clean" == *":"* ]]; then outbound_uuid="${uuid_pass_clean%:*}"; outbound_password2="${uuid_pass_clean#*:}"; else outbound_uuid="$uuid_pass_clean"; outbound_password2=""; fi
      if [[ "$rest" == *"?"* ]]; then host_port="${rest%%\?*}"; query="${rest#*\?}"; else host_port="$rest"; query=""; fi
      outbound_server="${host_port%:*}"
      outbound_port="${host_port#*:}"
      outbound_type="tuic"
      if [ -n "$query" ]; then
        sni=$(echo "$query" | grep -o 'sni=[^&]*' | cut -d= -f2); [ -n "$sni" ] && outbound_sni="$sni"
        fp=$(echo "$query" | grep -o 'fp=[^&]*' | cut -d= -f2); [ -n "$fp" ] && outbound_fingerprint="$fp"
        ins=$(echo "$query" | grep -o 'insecure=[^&]*' | cut -d= -f2); [ "$ins" = "1" ] || [ "$ins" = "true" ] && outbound_insecure="true"
        alins=$(echo "$query" | grep -o 'allowInsecure=[^&]*' | cut -d= -f2); [ "$alins" = "1" ] || [ "$alins" = "true" ] && outbound_insecure="true"
        cc=$(echo "$query" | grep -o 'congestion_control=[^&]*' | cut -d= -f2); [ -n "$cc" ] && outbound_congestion="$cc"
        alpn=$(echo "$query" | grep -o 'alpn=[^&]*' | cut -d= -f2); [ -n "$alpn" ] && outbound_alpn="$alpn"
      fi
      [ -z "$outbound_sni" ] && outbound_sni="$outbound_server"
      ;;
      
    anytls)
      password="${content%%@*}"
      rest="${content#*@}"
      if [[ "$rest" == *"?"* ]]; then host_port="${rest%%\?*}"; query="${rest#*\?}"; else host_port="$rest"; query=""; fi
      outbound_server="${host_port%:*}"
      outbound_port="${host_port#*:}"
      outbound_password="$password"
      outbound_type="anytls"
      if [ -n "$query" ]; then
        sni=$(echo "$query" | grep -o 'sni=[^&]*' | cut -d= -f2); [ -n "$sni" ] && outbound_sni="$sni"
        fp=$(echo "$query" | grep -o 'fp=[^&]*' | cut -d= -f2); [ -n "$fp" ] && outbound_fingerprint="$fp"
        ins=$(echo "$query" | grep -o 'insecure=[^&]*' | cut -d= -f2); [ "$ins" = "1" ] || [ "$ins" = "true" ] && outbound_insecure="true"
        alins=$(echo "$query" | grep -o 'allowInsecure=[^&]*' | cut -d= -f2); [ "$alins" = "1" ] || [ "$alins" = "true" ] && outbound_insecure="true"
      fi
      [ -z "$outbound_sni" ] && outbound_sni="$outbound_server"
      ;;

    socks5|socks)
      if [[ "$content" == *"@"* ]]; then
        user_pass="${content%%@*}"
        host_port="${content#*@}"
        decoded=$(echo "$user_pass" | base64 -d 2>/dev/null || true)
        if [ -n "$decoded" ] && [[ "$decoded" == *":"* ]]; then
          outbound_username="${decoded%:*}"
          outbound_password2="${decoded#*:}"
        else
          if [[ "$user_pass" == *":"* ]]; then
            outbound_username="${user_pass%:*}"
            outbound_password2="${user_pass#*:}"
          else
            outbound_username="$user_pass"
            outbound_password2=""
          fi
        fi
      else
        host_port="$content"
      fi
      outbound_server="${host_port%:*}"
      outbound_port="${host_port#*:}"
      outbound_type="socks"
      ;;

    *)
      echo "[WARN] 不支持的协议类型: $proto，跳过该节点"
      continue
      ;;
  esac

  if [ -z "$outbound_server" ] || [ -z "$outbound_port" ]; then
    echo "[WARN] 无法解析服务器地址或端口，跳过该节点"
    continue
  fi

  # 构建 outbound 对象
  jq_outbound="{\"type\":\"$outbound_type\",\"tag\":\"proxy\",\"server\":\"$outbound_server\",\"server_port\":$outbound_port"
  case "$outbound_type" in
    vless)
      jq_outbound="$jq_outbound,\"uuid\":\"$outbound_uuid\""
      [ -n "$outbound_flow" ] && jq_outbound="$jq_outbound,\"flow\":\"$outbound_flow\""
      if [ "$outbound_transport_type" != "tcp" ]; then jq_outbound="$jq_outbound,\"transport\":{\"type\":\"$outbound_transport_type\",\"path\":\"$outbound_path\",\"headers\":{\"Host\":\"$outbound_host\"}}"; fi
      tls_enabled="false"; [ "$outbound_security" = "tls" ] || [ "$outbound_security" = "reality" ] && tls_enabled="true"
      tls_json="{\"enabled\":$tls_enabled,\"server_name\":\"$outbound_sni\",\"insecure\":$outbound_insecure,\"utls\":{\"enabled\":true,\"fingerprint\":\"$outbound_fingerprint\"}"
      [ "$outbound_security" = "reality" ] && tls_json="$tls_json,\"reality\":{\"enabled\":true,\"public_key\":\"$outbound_reality_pbk\",\"short_id\":\"$outbound_reality_sid\"}"
      tls_json="$tls_json}"
      jq_outbound="$jq_outbound,\"tls\":$tls_json"
      ;;
    vmess)
      jq_outbound="$jq_outbound,\"uuid\":\"$outbound_uuid\",\"security\":\"auto\""
      jq_outbound="$jq_outbound,\"transport\":{\"type\":\"$outbound_transport_type\",\"path\":\"$outbound_path\",\"headers\":{\"Host\":\"$outbound_host\"}}"
      tls_enabled="false"; [ "$outbound_security" = "tls" ] && tls_enabled="true"
      jq_outbound="$jq_outbound,\"tls\":{\"enabled\":$tls_enabled,\"server_name\":\"$outbound_sni\",\"insecure\":$outbound_insecure,\"utls\":{\"enabled\":true,\"fingerprint\":\"$outbound_fingerprint\"}}"
      ;;
    trojan)
      jq_outbound="$jq_outbound,\"password\":\"$outbound_password\""
      jq_outbound="$jq_outbound,\"transport\":{\"type\":\"$outbound_transport_type\",\"path\":\"$outbound_path\",\"headers\":{\"Host\":\"$outbound_host\"}}"
      jq_outbound="$jq_outbound,\"tls\":{\"enabled\":true,\"server_name\":\"$outbound_sni\",\"insecure\":$outbound_insecure,\"utls\":{\"enabled\":true,\"fingerprint\":\"$outbound_fingerprint\"}}"
      ;;
    hysteria2)
      jq_outbound="$jq_outbound,\"up_mbps\":$outbound_up_mbps,\"down_mbps\":$outbound_down_mbps"
      [ -n "$outbound_obfs_password" ] && jq_outbound="$jq_outbound,\"obfs\":{\"type\":\"salamander\",\"password\":\"$outbound_obfs_password\"}"
      [ -n "$outbound_auth" ] && jq_outbound="$jq_outbound,\"password\":\"$outbound_auth\""
      jq_outbound="$jq_outbound,\"tls\":{\"enabled\":true,\"server_name\":\"$outbound_sni\",\"insecure\":$outbound_insecure}"
      ;;
    tuic)
      jq_outbound="$jq_outbound,\"uuid\":\"$outbound_uuid\""
      [ -n "$outbound_password2" ] && jq_outbound="$jq_outbound,\"password\":\"$outbound_password2\""
      jq_outbound="$jq_outbound,\"congestion_control\":\"$outbound_congestion\",\"udp_over_stream\":$outbound_udp_over_stream,\"zero_rtt_handshake\":$outbound_zerortt"
      tls_json="{\"enabled\":true,\"server_name\":\"$outbound_sni\",\"insecure\":$outbound_insecure"
      [ -n "$outbound_alpn" ] && tls_json="$tls_json,\"alpn\":[\"$outbound_alpn\"]"
      tls_json="$tls_json}"
      jq_outbound="$jq_outbound,\"tls\":$tls_json"
      ;;
    anytls)
      jq_outbound="$jq_outbound,\"password\":\"$outbound_password\""
      jq_outbound="$jq_outbound,\"tls\":{\"enabled\":true,\"server_name\":\"$outbound_sni\",\"insecure\":$outbound_insecure,\"utls\":{\"enabled\":true,\"fingerprint\":\"$outbound_fingerprint\"}}"
      ;;
    socks)
      [ -n "$outbound_username" ] && jq_outbound="$jq_outbound,\"username\":\"$outbound_username\""
      [ -n "$outbound_password2" ] && jq_outbound="$jq_outbound,\"password\":\"$outbound_password2\""
      jq_outbound="$jq_outbound,\"version\":\"$outbound_version\""
      ;;
  esac
  jq_outbound="$jq_outbound}"

  cat << EOF > sing-box-config.json
{
  "log": {"level": "warn"},
  "inbounds": [
    {"type": "socks", "tag": "socks-in", "listen": "127.0.0.1", "listen_port": 1080},
    {"type": "http", "tag": "http-in", "listen": "127.0.0.1", "listen_port": 1081}
  ],
  "outbounds": [$jq_outbound]
}
EOF

  # 每次切换节点前，清理旧进程防止端口占用
  pkill -f sing-box 2>/dev/null || true
  fuser -k 1080/tcp 2>/dev/null || true
  fuser -k 1081/tcp 2>/dev/null || true
  sleep 1

  ./sing-box run -c sing-box-config.json > sing-box.log 2>&1 &
  sleep 3

  # 测试当前节点的连通性
  echo "[INFO] 测试节点连接性..."
  ip_info=$(curl -x socks5://127.0.0.1:1080 -s --max-time 10 https://ipinfo.io/json || true)

  if [ -n "$ip_info" ] && echo "$ip_info" | jq -e '.ip' > /dev/null 2>&1; then
    ip_addr=$(echo "$ip_info" | jq -r '.ip // "Unknown"')
    country=$(echo "$ip_info" | jq -r '.country // "Unknown"')

    echo "[INFO] ✅ 节点 [$node_idx] 连接成功！ | 📍 IP: $ip_addr | 🌍 国家: $country"
    echo "IS_PROXY=true" >> $GITHUB_ENV
    echo "PROXY_SERVER=socks5://127.0.0.1:1080" >> $GITHUB_ENV
    exit 0
  else
    echo "[WARN] ❌ 节点 [$node_idx] 无法连接或超时，尝试下一个节点..."
  fi
done

echo "[ERROR] ❌ 所有配置的代理节点均测试失败！"
exit 1
