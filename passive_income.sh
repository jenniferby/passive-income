#!/bin/bash
# 融合版脚本：自动安装ProxyRack和RePocket

utf8_locale=$(locale -a 2>/dev/null | grep -i -m 1 -E "UTF-8|utf8")
if [[ -z "$utf8_locale" ]]; then
  echo "No UTF-8 locale found"
else
  export LC_ALL="$utf8_locale"
  export LANG="$utf8_locale"
  export LANGUAGE="$utf8_locale"
  echo "Locale set to $utf8_locale"
fi

if [ ! -d "/usr/local/bin" ]; then
  mkdir -p /usr/local/bin
fi

export DOCKER_DEFAULT_PLATFORM=linux/amd64

# 自定义字体彩色，read 函数，安装依赖函数
red() { echo -e "\033[31m\033[01m$1$2\033[0m"; }
green() { echo -e "\033[32m\033[01m$1$2\033[0m"; }
yellow() { echo -e "\033[33m\033[01m$1$2\033[0m"; }
reading() { read -rp "$(green "$1")" "$2"; }

# 必须以root运行脚本
check_root() {
  [[ $(id -u) != 0 ]] && red " The script must be run as root, you can enter sudo -i and then download and run again." && exit 1
}

# 判断系统，并选择相应的指令集
check_operating_system() {
  CMD=("$(grep -i pretty_name /etc/os-release 2>/dev/null | cut -d \" -f2)"
       "$(hostnamectl 2>/dev/null | grep -i system | cut -d : -f2)"
       "$(lsb_release -sd 2>/dev/null)" "$(grep -i description /etc/lsb-release 2>/dev/null | cut -d \" -f2)"
       "$(grep . /etc/redhat-release 2>/dev/null)"
       "$(grep . /etc/issue 2>/dev/null | cut -d \\ -f1 | sed '/^[ ]*$/d')"
      )

  for i in "${CMD[@]}"; do SYS="$i" && [[ -n $SYS ]] && break; done

  REGEX=("debian" "ubuntu" "raspbian" "centos|red hat|kernel|oracle linux|amazon linux|alma|rocky")
  RELEASE=("Debian" "Ubuntu" "Raspbian" "CentOS")
  PACKAGE_UPDATE=("apt -y update" "apt -y update" "apt -y update" "yum -y update")
  PACKAGE_INSTALL=("apt -y install" "apt -y install" "apt -y install" "yum -y install")
  PACKAGE_UNINSTALL=("apt -y autoremove" "apt -y autoremove" "apt -y autoremove" "yum -y autoremove")

  for ((int = 0; int < ${#REGEX[@]}; int++)); do
    [[ $(echo "$SYS" | tr '[:upper:]' '[:lower:]') =~ ${REGEX[int]} ]] && SYSTEM="${RELEASE[int]}" && break
  done

  [[ -z $SYSTEM ]] && red " ERROR: The script supports Debian, Ubuntu, CentOS or Alpine systems only.\n" && exit 1
}

# 判断宿主机的 IPv4 或双栈情况
check_ipv4() {
  # 遍历本机可以使用的 IP API 服务商
  # 定义可能的 IP API 服务商
  API_NET=("ip.sb" "ipget.net" "ip.ping0.cc" "https://ip4.seeip.org" "https://api.my-ip.io/ip" "https://ipv4.icanhazip.com" "api.ipify.org" "ifconfig.co")

  # 遍历每个 API 服务商，并检查它是否可用
  for p in "${API_NET[@]}"; do
    # 使用 curl 请求每个 API 服务商
    response=$(curl -s4m8 "$p")
    sleep 1
    # 检查请求是否失败，或者回传内容中是否包含 error
    if [ $? -eq 0 ] && ! echo "$response" | grep -q "error"; then
      # 如果请求成功且不包含 error，则设置 IP_API 并退出循环
      IP_API="$p"
      break
    fi
  done

  # 判断宿主机的 IPv4 、IPv6 和双栈情况
  ! curl -s4m8 $IP_API | grep -q '\.' && red " ERROR：The host must have IPv4. " && exit 1
}

# 判断 CPU 架构
check_virt() {
  ARCHITECTURE=$(uname -m)
  case "$ARCHITECTURE" in
    aarch64 ) 
      REPOCKET_ARCH=arm64
      PROXYRACK_SUPPORTED=0
      yellow " Warning: ProxyRack does not support ARM architecture, will only install RePocket.\n"
      ;;
    x64|x86_64|amd64 )
      REPOCKET_ARCH=amd64
      PROXYRACK_SUPPORTED=1
      ;;
    * ) red " ERROR: Unsupported architecture: $ARCHITECTURE\n" && exit 1 ;;
  esac
}

# 输入服务的个人信息
input_token() {
  [ -z $EMAIL ] && reading " Enter your RePocket Email, if you do not have an account, register at https://link.repocket.co/PBaK: " EMAIL 
  [ -z $PASSWORD ] && reading " Enter your RePocket API KEY: " PASSWORD
  
  if [ $PROXYRACK_SUPPORTED -eq 1 ]; then
    [ -z $PRTOKEN ] && reading " Enter your ProxyRack API Key, if you do not have an account, register at https://peer.proxyrack.com/ref/p28h60vn6bq3pznzx4bjuocdwqb5lrlb2tf3fksy: " PRTOKEN
  fi
}

# 为ProxyRack创建延迟注册脚本
create_delay_script() {
  cat > /tmp/delay_register.sh << 'EOF'
#!/bin/bash
PRTOKEN="$1"
uuid="$2"
dname="$3"

echo "Starting delayed registration with:"
echo "API Key: $PRTOKEN"
echo "UUID: $uuid"
echo "Device name: $dname"

# 等待2分钟
echo "Waiting 2 minutes before first registration attempt..."
sleep 2m

# 尝试最多5次，每次间隔3分钟
for attempt in {1..5}; do
  echo "Attempt $attempt to register device..."
  
  # 修复JSON格式问题，使用单引号包围整个数据部分
  response=$(curl -s \
    -X POST https://peer.proxyrack.com/api/device/add \
    -H "Api-Key: $PRTOKEN" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    -d '{"device_id":"'"$uuid"'","device_name":"'"$dname"'"}')
  
  echo "Response: $response"
  
  # 检查是否成功
  if [[ "$response" == *"status\":\"success"* ]]; then
    echo "Device registered successfully!"
    break
  else
    if [ $attempt -lt 5 ]; then
      echo "Registration failed, waiting 3 minutes before next attempt..."
      sleep 3m
    else
      echo "All registration attempts failed."
    fi
  fi
done
EOF

  chmod +x /tmp/delay_register.sh
}

# 安装Docker
install_docker() {
  green "\n Install docker.\n "
  if ! systemctl is-active docker >/dev/null 2>&1; then
    echo -e " \n Install docker \n "
    if [ $SYSTEM = "CentOS" ]; then
      ${PACKAGE_INSTALL[int]} yum-utils
      yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo &&
        ${PACKAGE_INSTALL[int]} docker-ce docker-ce-cli containerd.io
      systemctl enable --now docker
    else
      ${PACKAGE_INSTALL[int]} docker.io
    fi
  fi
}

# 创建TowerWatch
create_towerwatch() {
  [[ ! $(docker ps -a) =~ watchtower ]] && yellow " Create TowerWatch.\n " && docker run -d --name watchtower --restart always -p 2095:8080 -v /var/run/docker.sock:/var/run/docker.sock containrrr/watchtower --cleanup >/dev/null 2>&1
}

# 安装RePocket
install_repocket() {
  green "\n Starting RePocket installation...\n"
  
  # 删除旧容器（如有）
  docker ps -a | awk '{print $NF}' | grep -qw "repocket" && yellow " Remove the old repocket container.\n " && docker rm -f "repocket" 

  # 创建容器
  yellow " Create the repocket container.\n "
  docker run -e RP_EMAIL="$EMAIL" -e RP_API_KEY="$PASSWORD" -d --name "repocket" --restart=always repocket/repocket:latest

  # 显示结果
  docker ps -a | grep -q "repocket" && green " RePocket install success.\n" || red " RePocket install fail.\n"
}

# 安装ProxyRack
install_proxyrack() {
  # 如果不支持ProxyRack，则跳过
  if [ $PROXYRACK_SUPPORTED -eq 0 ]; then
    return
  fi
  
  green "\n Starting ProxyRack installation...\n"
  
  # 删除旧容器（如有）
  docker ps -a | awk '{print $NF}' | grep -qw "proxyrack" && yellow " Remove the old proxyrack container.\n " && docker rm -f "proxyrack" >/dev/null 2>&1

  # 创建容器
  yellow " Create the proxyrack container.\n "
  uuid=$(cat /dev/urandom | LC_ALL=C tr -dc 'A-F0-9' | dd bs=1 count=64 2>/dev/null)
  echo "${uuid}" >/usr/local/bin/proxyrack_uuid
  # 修改设备名称生成方式，添加随机数和时间戳
  timestamp=$(date +%s)
  random_num=$((RANDOM % 1000))
  dname="pr-${timestamp}-${random_num}"
  echo "${dname}" >/usr/local/bin/proxyrack_dname
  
  docker pull proxyrack/pop
  docker run -d --name "proxyrack" --restart always -e UUID="$uuid" proxyrack/pop
  
  # 创建并执行改进的延迟注册脚本
  create_delay_script
  echo "Starting device registration process in background..."
  nohup /tmp/delay_register.sh "$PRTOKEN" "$uuid" "$dname" > /tmp/proxyrack_register.log 2>&1 &
  
  # 显示结果
  sleep 5
  if docker ps -a | grep -q "proxyrack"; then
    green " Device id:" && cat /usr/local/bin/proxyrack_uuid 
    green " Device name:" && cat /usr/local/bin/proxyrack_dname
    green " ProxyRack install success."
    echo ""
    yellow " Device registration is running in background."
    yellow " You can check the registration process with: cat /tmp/proxyrack_register.log"
    echo ""
  else
    red " ProxyRack install fail.\n"
  fi
}

# 卸载
uninstall() {
  # 卸载RePocket
  docker ps -a | grep -qw "repocket" && yellow " Removing RePocket...\n" && docker rm -f $(docker ps -a | grep -w "repocket" | awk '{print $1}') && docker rmi -f $(docker images | grep repocket/repocket:latest | awk '{print $3}')
  
  # 卸载ProxyRack
  if docker ps -a | grep -qw "proxyrack"; then
    yellow " Removing ProxyRack...\n"
    uuid=$(cat /usr/local/bin/proxyrack_uuid 2>/dev/null || echo "unknown")
    echo "UUID: $uuid"
    docker rm -f $(docker ps -a | grep -w "proxyrack" | awk '{print $1}')
    docker rmi -f $(docker images | grep proxyrack/pop | awk '{print $3}')
    if [ -n "$PRTOKEN" ] && [ "$uuid" != "unknown" ]; then
      curl \
        -X POST https://peer.proxyrack.com/api/device/delete \
        -H "Api-Key: $PRTOKEN" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json" \
        -d "{\"device_id\":\"$uuid\"}" >/dev/null 2>&1
    fi
  fi
  
  # 卸载TowerWatch
  docker ps -a | grep -qw "watchtower" && yellow " Removing TowerWatch...\n" && docker rm -f watchtower && docker rmi -f $(docker images | grep containrrr/watchtower | awk '{print $3}')
  
  green "\n Uninstall complete.\n"
  exit 0
}

# 解析选项
while getopts "UuM:m:P:p:T:t:" OPTNAME; do
  case "$OPTNAME" in
    'U'|'u' ) UNINSTALL=1;;
    'M'|'m' ) EMAIL=$OPTARG;;
    'P'|'p' ) PASSWORD=$OPTARG;;
    'T'|'t' ) PRTOKEN=$OPTARG;;
  esac
done

# 主程序
check_root

if [ "$UNINSTALL" = "1" ]; then
  uninstall
else
  green "\n===== 开始安装被动收入服务 =====\n"
  check_operating_system
  check_ipv4
  check_virt
  input_token
  install_docker
  install_repocket
  install_proxyrack
  create_towerwatch
  green "\n===== 安装完成 =====\n"
fi
