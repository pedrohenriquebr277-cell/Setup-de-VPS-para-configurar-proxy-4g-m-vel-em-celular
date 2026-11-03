#!/usr/bin/env bash
# proxy4g - prepara a VPS para receber tuneis de celulares 4G e gera o bloco do celular.
#
#   proxy4g check              confere a VPS e arruma o que der
#   proxy4g novo N             confere + gera o bloco do celular N (N = 0..99)
#   proxy4g validar N          testa o celular N depois que o bloco rodou
#   proxy4g lista              mostra os celulares cadastrados
#   proxy4g revogar N          bloqueia o celular N
#
#   Opcao: --sem-corrigir      so confere, nao altera nada
#   Variaveis opcionais: PROXY_IP (IP publico da VPS), PROXY_BIND (endereco onde o proxy escuta)
#
# Fluxo: este script (VPS) -> bloco de texto -> colar no Termux do celular -> tunel sobe sozinho.

set -uo pipefail
export PATH="$PATH:/usr/sbin:/sbin:/usr/local/sbin"

CONF=/etc/celulares.conf
DIR="${PROXY4G_DIR:-/opt/celulares}"
HOSTPUB="${PROXY4G_HOSTPUB:-/etc/ssh/ssh_host_ed25519_key.pub}"
DROPIN=/etc/ssh/sshd_config.d/10-tunel.conf
TUSER=tunel
BASEPORT=1080
FIX=1; ERRS=0; WARNS=0; FIXES=0; BK=""
IP=""; SP=22; BIND=""; TUNEL_HOME=""; AKEYS=""

if [ -t 1 ]; then G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; B=$'\e[34m'; Z=$'\e[0m'; else G=""; Y=""; R=""; B=""; Z=""; fi
ok()    { echo "${G}[OK]${Z}       $*"; }
fixed() { echo "${B}[ARRUMEI]${Z}  $*"; FIXES=$((FIXES+1)); }
warn()  { echo "${Y}[AVISO]${Z}    $*"; WARNS=$((WARNS+1)); }
err()   { echo "${R}[ERRO]${Z}     $*"; ERRS=$((ERRS+1)); }
info()  { echo "            $*"; }

have()      { command -v "$1" >/dev/null 2>&1; }
is_ip()     { [[ "${1:-}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }
is_num()    { [[ "${1:-}" =~ ^[0-9]+$ ]]; }
sshd_val()  { sshd -T 2>/dev/null | awk -v k="$1" '$1==k {sub(/^[^ ]+ /,""); print; exit}'; }
ssh_svc()   { local s; for s in ssh sshd; do if systemctl cat "$s" >/dev/null 2>&1; then echo "$s"; return; fi; done; }
host_has_ip() { ip -4 -o addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | grep -qx "$1"; }
listening() { ss -ltn 2>/dev/null | awk 'NR>1{print $4}' | grep -qx "$1"; }

backup() {
  [ -e "$1" ] || return 0
  if [ -z "$BK" ]; then BK="/root/backup-proxy4g-$(date +%F-%H%M%S)"; mkdir -p "$BK"; fi
  cp -a "$1" "$BK/$(echo "$1" | tr / _)"
}

reload_sshd() {
  local s; s=$(ssh_svc)
  if [ -n "$s" ]; then
    systemctl reload "$s" >/dev/null 2>&1 || systemctl restart "$s" >/dev/null 2>&1
  elif [ -f /run/sshd.pid ]; then
    kill -HUP "$(cat /run/sshd.pid)"
  else
    return 1
  fi
}

set_paths() {
  TUNEL_HOME=$(getent passwd "$TUSER" | cut -d: -f6)
  AKEYS="$TUNEL_HOME/.ssh/authorized_keys"
}

# ------------------------------------------------------------------ CHECAGENS

p_tools() {
  local miss=() t
  for t in ssh-keygen sshd curl ss ip awk sed base64 sha256sum; do have "$t" || miss+=("$t"); done
  if [ ${#miss[@]} -gt 0 ] && [ "$FIX" = 1 ] && have apt-get; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y openssh-server openssh-client curl iproute2 coreutils sed gawk >/dev/null 2>&1 \
      || { apt-get update -qq >/dev/null 2>&1; DEBIAN_FRONTEND=noninteractive apt-get install -y openssh-server openssh-client curl iproute2 coreutils sed gawk >/dev/null 2>&1; }
    local still=()
    for t in "${miss[@]}"; do have "$t" || still+=("$t"); done
    if [ ${#still[@]} -eq 0 ]; then fixed "instalei o que faltava: ${miss[*]}"; return; fi
    miss=("${still[@]}")
  fi
  if [ ${#miss[@]} -gt 0 ]; then err "faltam programas: ${miss[*]} (instale com apt-get install)"; else ok "programas necessarios presentes"; fi
}

p_sshd() {
  if [ ! -f "$HOSTPUB" ]; then
    if [ "$FIX" = 1 ]; then ssh-keygen -A >/dev/null 2>&1; fi
    if [ -f "$HOSTPUB" ]; then fixed "gerei as chaves do servidor SSH"; else err "sem chave ed25519 do servidor SSH ($HOSTPUB)"; fi
  else
    ok "chave ed25519 do servidor SSH presente"
  fi
  SP=$(sshd_val port)
  if ! is_num "$SP"; then err "sshd -T falhou. Rode 'sshd -T' e veja o erro"; SP=22; return; fi
  if listening "0.0.0.0:$SP" || listening "[::]:$SP" || listening "*:$SP"; then
    ok "sshd escutando na porta $SP"
  else
    if [ "$FIX" = 1 ]; then
      local s; s=$(ssh_svc)
      [ -n "$s" ] && systemctl enable --now "$s" >/dev/null 2>&1
      sleep 1
    fi
    if listening "0.0.0.0:$SP" || listening "[::]:$SP" || listening "*:$SP"; then fixed "subi o sshd na porta $SP"
    else err "sshd nao esta escutando na porta $SP"; fi
  fi
}

p_conf() {
  local cIP="" cSP="" cBIND="" gw=""
  if [ -f "$CONF" ]; then
    cIP=$(sed -n 's/^IP=//p' "$CONF" | head -n1)
    cSP=$(sed -n 's/^SP=//p' "$CONF" | head -n1)
    cBIND=$(sed -n 's/^BIND=//p' "$CONF" | head -n1)
  fi
  IP="${PROXY_IP:-$cIP}"
  BIND="${PROXY_BIND:-$cBIND}"
  if [ -z "$IP" ]; then
    IP=$(curl -s -m 10 https://api.ipify.org 2>/dev/null || true)
    is_ip "$IP" && warn "IP publico da VPS detectado como $IP. Confirme que e o mesmo usado no seu ssh (se nao for: PROXY_IP=x.x.x.x proxy4g check)"
  fi
  if [ -z "$BIND" ]; then
    gw=$(ip -4 -o addr show docker_gwbridge 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)
    if [ -n "$gw" ]; then BIND="$gw"; info "Docker Swarm detectado: proxy vai escutar em $BIND"; else BIND="127.0.0.1"; fi
  fi
  is_ip "$IP"   || { err "IP publico invalido ('$IP'). Use PROXY_IP=x.x.x.x"; return; }
  is_ip "$BIND" || { err "BIND invalido ('$BIND'). Use PROXY_BIND=x.x.x.x"; return; }
  if ! host_has_ip "$BIND"; then err "o endereco $BIND nao existe nesta maquina (ip -4 addr)"; return; fi
  if [ "$cIP" != "$IP" ] || [ "$cSP" != "$SP" ] || [ "$cBIND" != "$BIND" ]; then
    if [ "$FIX" = 1 ]; then
      backup "$CONF"
      printf 'IP=%s\nSP=%s\nBIND=%s\n' "$IP" "$SP" "$BIND" > "$CONF"
      fixed "gravei $CONF (IP=$IP SP=$SP BIND=$BIND)"
    else
      warn "$CONF desatualizado (esperado IP=$IP SP=$SP BIND=$BIND)"
    fi
  else
    ok "config: IP=$IP, SSH porta $SP, proxy escuta em $BIND"
  fi
}

p_user() {
  if id "$TUSER" >/dev/null 2>&1; then
    ok "usuario $TUSER existe"
  elif [ "$FIX" = 1 ]; then
    adduser --disabled-password --gecos "" "$TUSER" >/dev/null 2>&1 || useradd -m -s /bin/bash "$TUSER" >/dev/null 2>&1
    if id "$TUSER" >/dev/null 2>&1; then fixed "criei o usuario $TUSER"; else err "nao consegui criar o usuario $TUSER"; fi
  else
    err "usuario $TUSER nao existe"
  fi
  id "$TUSER" >/dev/null 2>&1 || return
  set_paths

  local pw; pw=$(getent shadow "$TUSER" | cut -d: -f2)
  case "$pw" in
    '!'*) if [ "$FIX" = 1 ]; then usermod -p '*' "$TUSER" && fixed "destravei a conta $TUSER (so entra por chave)"; else err "conta $TUSER travada (usermod -p '*' $TUSER)"; fi ;;
  esac

  local hp; hp=$(stat -c %a "$TUNEL_HOME" 2>/dev/null || echo 755)
  if [ $((8#$hp & 8#022)) -ne 0 ]; then
    if [ "$FIX" = 1 ]; then chmod go-w "$TUNEL_HOME"; fixed "tirei escrita de grupo/outros da pasta $TUNEL_HOME"; else err "pasta $TUNEL_HOME com escrita para grupo/outros"; fi
  fi

  local d="$TUNEL_HOME/.ssh" st
  st=$(stat -c '%a %U' "$d" 2>/dev/null || echo "none")
  if [ "$st" != "700 $TUSER" ]; then
    if [ "$FIX" = 1 ]; then install -d -m 700 -o "$TUSER" -g "$TUSER" "$d"; fixed "ajustei $d (700, dono $TUSER)"; else err "$d com permissao errada ($st)"; fi
  fi
  st=$(stat -c '%a %U' "$AKEYS" 2>/dev/null || echo "none")
  if [ "$st" != "600 $TUSER" ]; then
    if [ "$FIX" = 1 ]; then
      [ -f "$AKEYS" ] || : > "$AKEYS"
      chown "$TUSER:$TUSER" "$AKEYS"; chmod 600 "$AKEYS"
      fixed "ajustei $AKEYS (600, dono $TUSER)"
    else err "$AKEYS com permissao errada ($st)"; fi
  else
    ok "$AKEYS com permissoes corretas"
  fi
}

BAD=()
sshd_effective_ok() {
  BAD=()
  local ci cc gp pk
  ci=$(sshd_val clientaliveinterval); cc=$(sshd_val clientalivecountmax)
  gp=$(sshd_val gatewayports);        pk=$(sshd_val pubkeyauthentication)
  if ! { is_num "$ci" && [ "$ci" -ge 1 ] && [ "$ci" -le 60 ]; }; then BAD+=("ClientAliveInterval=${ci:-?} (precisa 1 a 60)"); fi
  if ! { is_num "$cc" && [ "$cc" -ge 1 ]; }; then BAD+=("ClientAliveCountMax=${cc:-?}"); fi
  case "$gp" in clientspecified|yes) ;; *) BAD+=("GatewayPorts=${gp:-?}") ;; esac
  [ "$pk" = yes ] || BAD+=("PubkeyAuthentication=${pk:-?}")
  [ ${#BAD[@]} -eq 0 ]
}

p_sshd_cfg() {
  # travas que o script NAO mexe (servidor endurecido de proposito): so avisa
  local tf df au ag
  tf=$(sshd_val allowtcpforwarding); df=$(sshd_val disableforwarding)
  case "$tf" in yes|all) ;; *) err "AllowTcpForwarding=${tf:-?} no sshd. Sem isso o tunel nao funciona. Adicione 'Match User $TUSER' + 'AllowTcpForwarding yes' no fim do sshd_config" ;; esac
  [ "$df" = yes ] && err "DisableForwarding yes no sshd. Libere para o usuario $TUSER (Match User $TUSER)"
  au=$(sshd_val allowusers)
  if [ -n "$au" ]; then
    case " $au " in *" $TUSER "*|*" * "*) ;; *) err "AllowUsers existe e nao inclui $TUSER. Adicione $TUSER na linha AllowUsers do sshd_config" ;; esac
  fi
  ag=$(sshd_val allowgroups)
  if [ -n "$ag" ] && id "$TUSER" >/dev/null 2>&1; then
    local g hit=0
    for g in $(id -Gn "$TUSER"); do case " $ag " in *" $g "*|*" * "*) hit=1 ;; esac; done
    [ "$hit" = 1 ] || err "AllowGroups existe e nenhum grupo de $TUSER esta nela. Adicione o grupo $TUSER em AllowGroups"
  fi

  if sshd_effective_ok; then
    ok "sshd configurado (keepalive 30s, GatewayPorts, chave publica)"
    return
  fi
  info "sshd fora do esperado: ${BAD[*]}"
  if [ "$FIX" != 1 ]; then err "sshd precisa de ajuste (rode sem --sem-corrigir)"; return; fi

  backup "$DROPIN"; backup /etc/ssh/sshd_config
  local had=0; [ -f "$DROPIN" ] && had=1
  if ! grep -qiE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/' /etc/ssh/sshd_config; then
    mkdir -p /etc/ssh/sshd_config.d
    sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config
    info "adicionei 'Include sshd_config.d' no topo do sshd_config"
  fi
  mkdir -p /etc/ssh/sshd_config.d
  cat > "$DROPIN" <<'CFG'
# gerado por proxy4g - tuneis dos celulares 4G
ClientAliveInterval 30
ClientAliveCountMax 3
GatewayPorts clientspecified
PubkeyAuthentication yes
CFG
  if ! sshd -t 2>/tmp/proxy4g_sshd_err; then
    err "config do sshd invalida, desfiz a alteracao: $(head -n1 /tmp/proxy4g_sshd_err)"
    if [ "$had" = 1 ]; then cp -a "$BK/$(echo "$DROPIN" | tr / _)" "$DROPIN"; else rm -f "$DROPIN"; fi
    [ -f "$BK/_etc_ssh_sshd_config" ] && cp -a "$BK/_etc_ssh_sshd_config" /etc/ssh/sshd_config
    return
  fi
  if ! reload_sshd; then err "nao consegui recarregar o sshd (systemctl reload ssh)"; return; fi
  sleep 1
  if sshd_effective_ok; then fixed "configurei o sshd ($DROPIN) e recarreguei sem derrubar sessoes"
  else err "sshd continua fora do esperado: ${BAD[*]}. Algum arquivo em /etc/ssh/sshd_config.d sobrepoe o meu"; fi
}

p_firewall() {
  if have ufw && ufw status 2>/dev/null | head -n1 | grep -qi 'status: active'; then
    if [ "$BIND" = "127.0.0.1" ]; then
      ok "ufw ativo; proxy em 127.0.0.1, nao precisa de regra"
    elif ufw status 2>/dev/null | grep -qE '1080:1179'; then
      ok "ufw ativo com regra para as portas de proxy (1080:1179)"
    elif [ "$FIX" = 1 ]; then
      ufw allow from 172.16.0.0/12 to any port 1080:1179 proto tcp comment proxy4g >/dev/null 2>&1 \
        && fixed "liberei no ufw 172.16.0.0/12 -> portas 1080:1179" || err "nao consegui criar a regra do ufw"
    else
      err "ufw ativo sem regra para 1080:1179 (containers nao alcancam o proxy)"
    fi
  else
    ok "sem ufw ativo (se o teste do container falhar, confira iptables ou o firewall do provedor)"
  fi
  if have systemctl && systemctl is-active fail2ban >/dev/null 2>&1; then
    warn "fail2ban ativo: se o celular errar a chave varias vezes, o IP dele pode ser banido (fail2ban-client status sshd)"
  fi
}

p_dirs() {
  local st; st=$(stat -c '%a' "$DIR" 2>/dev/null || echo none)
  if [ "$st" = "700" ]; then ok "$DIR existe (700)"
  elif [ "$FIX" = 1 ]; then mkdir -p "$DIR"; chmod 700 "$DIR"; fixed "criei/ajustei $DIR (700)"
  else err "$DIR ausente ou com permissao errada ($st)"; fi
}

p_net() {
  local x; x=$(curl -s -m 10 https://api.ipify.org 2>/dev/null || true)
  if is_ip "$x"; then ok "VPS tem internet (IP de saida $x)"; else warn "VPS sem internet para api.ipify.org: o comando validar vai falhar"; fi
}

preflight() {
  ERRS=0; WARNS=0; FIXES=0
  [ "$FIX" = 1 ] && echo "== Checando a VPS (corrigindo o que for possivel) ==" || echo "== Checando a VPS (so leitura) =="
  p_tools
  p_sshd
  p_conf
  p_user
  p_sshd_cfg
  p_firewall
  p_dirs
  p_net
  echo
  [ -n "$BK" ] && echo "Backup dos arquivos alterados: $BK"
  if [ "$ERRS" -gt 0 ]; then
    echo "${R}VPS NAO PRONTA: $ERRS erro(s), $WARNS aviso(s), $FIXES correcao(oes).${Z}"
    return 1
  fi
  echo "${G}VPS PRONTA: 0 erros, $WARNS aviso(s), $FIXES correcao(oes).${Z}"
  return 0
}

# ------------------------------------------------------------------ BLOCO DO CELULAR

render_installer() {  # $1=N  $2=porta do proxy ; usa IP SP BIND DIR HOSTPUB
  local n="$1" pp="$2" hk known
  if [ "$SP" = "22" ]; then hk="$IP"; else hk="[$IP]:$SP"; fi
  known="$hk $(cut -d' ' -f1,2 "$HOSTPUB")"
  sed -e "s|%%N%%|$n|g" -e "s|%%IP%%|$IP|g" -e "s|%%SP%%|$SP|g" \
      -e "s|%%PP%%|$pp|g" -e "s|%%BIND%%|$BIND|g" -e "s|%%KNOWN%%|$known|g" \
      -e "/%%PRIVKEY%%/r $DIR/cel$n" -e "/%%PRIVKEY%%/d" <<'TPL'
#!/data/data/com.termux/files/usr/bin/sh
# Instalador do tunel 4G - celular %%N%% - gerado por proxy4g
set -e
H=/data/data/com.termux/files/home
export DEBIAN_FRONTEND=noninteractive
echo ">> 1/5 atualizando pacotes (pode levar alguns minutos)"
pkg update -y
apt-get -y -o Dpkg::Options::=--force-confnew upgrade
echo ">> 2/5 instalando openssh"
pkg install -y openssh
echo ">> 3/5 gravando chave e servidor conhecido"
mkdir -p $H/.ssh $H/.termux/boot
chmod 700 $H/.ssh
cat > $H/.ssh/tunel <<'EOF'
%%PRIVKEY%%
EOF
chmod 600 $H/.ssh/tunel
echo '%%KNOWN%%' > $H/.ssh/tunel_known_hosts
chmod 600 $H/.ssh/tunel_known_hosts
echo ">> 4/5 criando o script que roda no boot"
cat > $H/.termux/boot/10-tunel.sh <<'EOF'
#!/data/data/com.termux/files/usr/bin/sh
export PATH=/data/data/com.termux/files/usr/bin:$PATH
H=/data/data/com.termux/files/home
exec >> $H/tunel.log 2>&1
termux-wake-lock
while true; do
  echo "$(date '+%F %T') conectando"
  ssh -N -i $H/.ssh/tunel -p %%SP%% \
    -o BatchMode=yes -o IdentitiesOnly=yes \
    -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$H/.ssh/tunel_known_hosts \
    -o HostKeyAlgorithms=ssh-ed25519 \
    -o ConnectTimeout=15 -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \
    -o ExitOnForwardFailure=yes \
    -R %%BIND%%:%%PP%% tunel@%%IP%%
  RC=$?
  echo "$(date '+%F %T') caiu, codigo $RC"
  sleep 10
done
EOF
chmod +x $H/.termux/boot/10-tunel.sh
echo ">> 5/5 iniciando o tunel"
pkill -f 10-tunel.sh 2>/dev/null || true
pkill -f 'tunel@' 2>/dev/null || true
: > $H/tunel.log
nohup sh $H/.termux/boot/10-tunel.sh > /dev/null 2>&1 &
sleep 15
if pgrep -f 'tunel@' > /dev/null; then echo "RESULTADO: TUNEL ATIVO"; else echo "RESULTADO: TUNEL FALHOU"; fi
tail -n 5 $H/tunel.log
ls -l $H/.termux/boot
rm -f $H/instalar.sh
echo "FIM. Saia pelo botao Home. Nao digite exit. Deixe o Wi-Fi desligado."
TPL
}

build_block() {  # $1=N $2=porta ; imprime a linha unica do bloco
  local tmp b64 hash
  tmp=$(mktemp)
  render_installer "$1" "$2" > "$tmp"
  b64=$(base64 -w0 < "$tmp")
  hash=$(sha256sum < "$tmp" | cut -d' ' -f1)
  rm -f "$tmp"
  printf "cd ~ && echo '%s' | base64 -d > instalar.sh && echo '%s  instalar.sh' | sha256sum -c - && sh instalar.sh || echo 'ERRO: bloco incompleto ou falha na instalacao. Copie o bloco inteiro de novo.'\n" "$b64" "$hash"
}

check_n() {
  if ! is_num "${1:-}" || [ "$1" -gt 99 ]; then echo "N precisa ser um numero de 0 a 99"; exit 1; fi
}

load_conf() {
  if [ ! -f "$CONF" ]; then err "$CONF nao existe. Rode: proxy4g check"; return 1; fi
  IP=$(sed -n 's/^IP=//p' "$CONF" | head -n1); SP=$(sed -n 's/^SP=//p' "$CONF" | head -n1); BIND=$(sed -n 's/^BIND=//p' "$CONF" | head -n1)
  id "$TUSER" >/dev/null 2>&1 && set_paths
  return 0
}

cmd_novo() {
  local n="$1" pp k line tmp out
  check_n "$n"
  pp=$((BASEPORT+n))
  if ! preflight; then echo "Bloco NAO gerado. Corrija os erros acima e rode de novo."; return 1; fi
  [ "$FIX" = 1 ] || { echo "Bloco nao gerado em modo --sem-corrigir."; return 0; }
  k="$DIR/cel$n"
  if [ -f "$k" ]; then
    info "celular $n ja tinha chave: reaproveitando"
  else
    ssh-keygen -q -t ed25519 -N "" -C "cel$n" -f "$k" && chmod 600 "$k"
  fi
  [ -f "$k.pub" ] || ssh-keygen -y -f "$k" > "$k.pub"
  line="restrict,port-forwarding,command=\"/bin/false\",permitlisten=\"$BIND:$pp\" $(cut -d' ' -f1,2 "$k.pub") cel$n"
  tmp=$(mktemp)
  grep -v " cel$n\$" "$AKEYS" > "$tmp" || true
  echo "$line" >> "$tmp"
  install -m 600 -o "$TUSER" -g "$TUSER" "$tmp" "$AKEYS"; rm -f "$tmp"
  out="$DIR/bloco-cel$n.txt"
  build_block "$n" "$pp" > "$out"; chmod 600 "$out"
  echo
  echo "${G}Bloco do celular $n gerado.${Z}  Arquivo: $out ($(wc -c < "$out") bytes)"
  echo "  Porta do proxy nesta VPS: $BIND:$pp (socks5)"
  echo "  Para pegar o bloco:       cat $out"
  echo "  Envie por Telegram (Mensagens salvas) ou Google Keep e APAGUE depois de colar."
  echo "  O bloco contem a chave privada deste celular (so abre a porta $pp; revogue com: proxy4g revogar $n)."
  echo
  echo "Antes da Isa colar: Termux e Termux:Boot instalados pelo F-Droid, Termux:Boot aberto 1 vez,"
  echo "bateria sem restricao nos dois, Wi-Fi desligado, dados moveis ligados."
  echo "Depois que ela colar e aparecer 'TUNEL ATIVO': proxy4g validar $n"
}

cmd_validar() {
  local n="$1" pp d p1 p2 p3 org city c r
  check_n "$n"; pp=$((BASEPORT+n))
  load_conf || return 1
  ERRS=0; WARNS=0
  echo "== Validando celular $n (proxy $BIND:$pp) =="
  [ -f "$DIR/cel$n" ] || { err "celular $n nao foi gerado. Rode: proxy4g novo $n"; return 1; }
  grep -q " cel$n\$" "$AKEYS" 2>/dev/null && ok "chave do celular $n autorizada" || err "chave do celular $n nao esta autorizada. Rode: proxy4g novo $n"

  if listening "$BIND:$pp"; then
    ok "tunel conectado (porta $BIND:$pp aberta)"
  else
    err "tunel NAO conectado. O bloco nao rodou, o Termux foi fechado, ou o celular esta sem dados."
    info "ultimas linhas do log do SSH sobre o tunel:"
    (grep -h "$TUSER" /var/log/auth.log 2>/dev/null || journalctl -u ssh -u sshd --no-pager 2>/dev/null | grep "$TUSER") | tail -n 6 | sed 's/^/            /'
    echo "${R}VALIDACAO FALHOU${Z}"; return 1
  fi

  d=$(curl -s -m 15 https://api.ipify.org 2>/dev/null || true)
  p1=$(curl -s -m 25 --socks5-hostname "$BIND:$pp" https://api.ipify.org 2>/dev/null || true)
  if ! is_ip "$p1"; then err "proxy sem saida para a internet (celular sem dados moveis?)"
  elif [ "$p1" = "$d" ]; then err "IP pelo proxy ($p1) e igual ao da VPS. O proxy nao esta usando o 4G"
  else ok "IP de saida pelo proxy: $p1 (VPS: ${d:-?})"; fi

  if is_ip "$p1"; then
    sleep 3; p2=$(curl -s -m 25 --socks5-hostname "$BIND:$pp" https://api.ipify.org 2>/dev/null || true)
    sleep 3; p3=$(curl -s -m 25 --socks5-hostname "$BIND:$pp" https://api.ipify.org 2>/dev/null || true)
    if [ "$p1" = "$p2" ] && [ "$p2" = "$p3" ]; then ok "IP estavel em 3 consultas"; else warn "IP mudou durante o teste ($p1, $p2, $p3). A operadora esta trocando o IP"; fi
    r=$(curl -s -m 20 --socks5-hostname "$BIND:$pp" https://ipinfo.io/json 2>/dev/null || true)
    org=$(echo "$r" | sed -n 's/.*"org": *"\([^"]*\)".*/\1/p' | head -n1)
    city=$(echo "$r" | sed -n 's/.*"city": *"\([^"]*\)".*/\1/p' | head -n1)
    if [ -n "$org" ]; then
      if echo "$org" | grep -qiE 'amazon|google|digitalocean|ovh|hetzner|vultr|linode|microsoft|contabo|oracle|cloudflare|hosting|datacenter'; then
        err "o IP pertence a datacenter ($org), nao a operadora movel. Wi-Fi do celular ligado?"
      else
        ok "operadora: $org ${city:+($city)}  (confira se e a do chip)"
      fi
    else
      warn "nao consegui consultar a operadora (ipinfo.io limitou ou falhou)"
    fi
  fi

  if [ "$BIND" != "127.0.0.1" ] && have docker; then
    c=$(docker ps -q --filter name=evolution 2>/dev/null | head -n1)
    if [ -z "$c" ]; then warn "nao achei container da Evolution para testar o alcance (docker ps)"
    elif ! timeout 10 docker exec "$c" sh -c 'command -v node' >/dev/null 2>&1; then warn "container da Evolution sem node: teste de alcance pulado"
    elif timeout 15 docker exec "$c" node -e "setTimeout(()=>process.exit(2),5000);require('net').connect($pp,'$BIND').on('connect',()=>process.exit(0)).on('error',()=>process.exit(1))" >/dev/null 2>&1; then
      ok "container da Evolution alcanca $BIND:$pp"
    else
      err "container da Evolution NAO alcanca $BIND:$pp (firewall? Rode: proxy4g check)"
    fi
  fi

  echo
  if [ "$ERRS" -gt 0 ]; then echo "${R}VALIDACAO FALHOU: $ERRS erro(s), $WARNS aviso(s).${Z}"; return 1; fi
  echo "${G}CELULAR $n OK${Z} ($WARNS aviso(s)). Na Evolution, por instancia, antes de ler o QR:"
  echo "  host: $BIND   port: $pp   protocol: socks5   username/password: vazios"
  echo "Teste final: no celular, derrube o tunel (pkill -f tunel@); a instancia tem que perder conexao."
}

cmd_lista() {
  load_conf >/dev/null 2>&1 || true
  printf '%-5s %-18s %-12s %s\n' CEL PROXY TUNEL AUTORIZADO
  local pub n any=0
  for pub in "$DIR"/cel*.pub; do
    [ -e "$pub" ] || break
    any=1
    n=$(basename "$pub" .pub); n=${n#cel}
    printf '%-5s %-18s %-12s %s\n' "$n" "${BIND:-?}:$((BASEPORT+n))" \
      "$(listening "${BIND:-x}:$((BASEPORT+n))" && echo conectado || echo desconectado)" \
      "$(grep -q " cel$n\$" "${AKEYS:-/dev/null}" 2>/dev/null && echo sim || echo nao)"
  done
  [ "$any" = 1 ] || echo "(nenhum celular cadastrado)"
}

cmd_revogar() {
  local n="$1" ts; check_n "$n"
  load_conf || return 1
  ts=$(date +%F-%H%M%S)
  sed -i "/ cel$n\$/d" "$AKEYS"
  mkdir -p "$DIR/revogados"
  for f in "$DIR/cel$n" "$DIR/cel$n.pub" "$DIR/bloco-cel$n.txt"; do [ -e "$f" ] && mv "$f" "$DIR/revogados/$(basename "$f").$ts"; done
  echo "Celular $n revogado. Novas conexoes com a chave antiga sao recusadas."
  echo "Se o tunel ainda estiver aberto, ele cai sozinho no proximo keepalive ou derrube: pkill -u $TUSER -f 'sshd: $TUSER'  (derruba TODOS os celulares por ~10s)"
}

usage() {
  sed -n '2,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

main() {
  local cmd="${1:-}"; shift || true
  local args=() a
  for a in "$@"; do case "$a" in --sem-corrigir) FIX=0 ;; *) args+=("$a") ;; esac; done
  case "$cmd" in
    check|novo|validar|lista|revogar) ;;
    *) usage; exit 1 ;;
  esac
  [ "$(id -u)" -eq 0 ] || { echo "Rode como root."; exit 1; }
  case "$cmd" in
    check)   preflight ;;
    novo)    [ -n "${args[0]:-}" ] || { usage; exit 1; }; cmd_novo "${args[0]}" ;;
    validar) [ -n "${args[0]:-}" ] || { usage; exit 1; }; cmd_validar "${args[0]}" ;;
    lista)   cmd_lista ;;
    revogar) [ -n "${args[0]:-}" ] || { usage; exit 1; }; cmd_revogar "${args[0]}" ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
