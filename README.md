# proxy4g

Transforma celulares Android com chip 4G em saídas de proxy para instâncias do WhatsApp (Evolution API) rodando em uma VPS. Cada celular abre um túnel SSH reverso até a VPS, e a VPS ganha um proxy SOCKS5 que sai pelo IP móvel do chip.

O script automatiza o lado da VPS (verificar, corrigir, gerar o bloco do celular, validar). No celular, a pessoa só instala o Termux e cola um bloco de texto.

> Status: validado apenas em partes (sintaxe, geração e decodificação do bloco, chave embutida). O comportamento ponta a ponta (sshd real, Docker Swarm, Termux, túnel em produção) depende do seu ambiente e deve ser conferido no primeiro celular antes de escalar.

## Como funciona

```
Evolution API ──► VPS (BIND:1080+N) ◄── túnel SSH reverso ◄── Termux (celular N) ──► internet 4G
   (container)        proxy SOCKS5                                                  (IP da operadora)
```

- O celular abre uma conexão **de saída** para a VPS (a operadora usa CGNAT, então entrada direta não funciona).
- Essa conexão pede ao `sshd` da VPS para escutar a porta `1080+N` e repassar o tráfego pelo celular (`ssh -R`, SOCKS dinâmico).
- A Evolution usa `host=BIND`, `port=1080+N`, `protocol=socks5` na configuração de proxy da instância.
- Cada celular tem a **própria chave**, que só pode abrir a **própria porta** (`permitlisten`), sem shell.
- Não há acesso remoto ao celular: só o túnel do proxy. Para corrigir um celular, é preciso alguém no aparelho.

## Requisitos

**VPS**
- Linux com systemd, `root`, OpenSSH server, `curl`, `iproute2`.
- IP público acessível pelo celular na porta do SSH.
- Se a Evolution roda em Docker Swarm, o proxy escuta no gateway `docker_gwbridge` (detectado automaticamente). Fora do Swarm, escuta em `127.0.0.1`.

**Celular (Android)**
- Termux e Termux:Boot instalados pelo **F-Droid** (não pela Play Store; as duas precisam vir da mesma fonte).
- Chip com dados móveis e franquia (estimativa: ~1,5 GB por instância por mês com 1 áudio e 1 imagem por lead, e o dobro disso se contar ida e volta pelo túnel).
- iPhone não serve.

## Instalação na VPS

```bash
scp ./proxy4g.sh root@IP_DA_VPS:/root/
ssh root@IP_DA_VPS
install -m 755 /root/proxy4g.sh /usr/local/bin/proxy4g
proxy4g check --sem-corrigir   # só leitura: mostra o que falta
proxy4g check                  # confere e corrige
```

## Comandos

| Comando | O que faz |
|---|---|
| `proxy4g check` | Confere a VPS e corrige o que for possível. Cada item sai como `OK`, `ARRUMEI` ou `ERRO`. |
| `proxy4g check --sem-corrigir` | Só leitura. Não altera nada. |
| `proxy4g novo N` | Roda o `check`. Se tudo estiver OK, gera a chave e o bloco do celular `N` (0 a 99). Se houver erro, não gera. |
| `proxy4g validar N` | Testa o celular `N` depois que o bloco rodou: túnel aberto, IP de saída diferente do da VPS, estabilidade em 3 consultas, operadora e alcance a partir do container da Evolution. |
| `proxy4g lista` | Lista os celulares cadastrados e se o túnel está conectado. |
| `proxy4g revogar N` | Remove a autorização do celular `N` e arquiva as chaves em `/opt/celulares/revogados/`. |

Variáveis opcionais (para o `check`/`novo`):

| Variável | Uso |
|---|---|
| `PROXY_IP` | Força o IP público da VPS usado pelo celular (se a detecção automática errar). |
| `PROXY_BIND` | Força o endereço onde o proxy escuta (ex.: `127.0.0.1` ou o gateway do Docker). |

### O que o `check` verifica e corrige

- Programas necessários (`ssh-keygen`, `sshd`, `curl`, `ss`, `ip`, `base64`, `sha256sum`). Instala via `apt-get` se faltar.
- Chaves do servidor SSH e `sshd` escutando.
- `/etc/celulares.conf` (`IP`, `SP`, `BIND`).
- Usuário `tunel` (sem senha, só chave), permissões de `~/.ssh` e `authorized_keys`, conta destravada.
- `sshd`: `ClientAliveInterval 30`, `ClientAliveCountMax 3`, `GatewayPorts clientspecified`, `PubkeyAuthentication yes` (via `/etc/ssh/sshd_config.d/10-tunel.conf`, com `sshd -t` antes de recarregar e rollback se falhar).
- Regra do `ufw` para as portas `1080:1179`, quando o proxy não está em loopback.
- `/opt/celulares` (permissão 700) e acesso à internet.

O que o script **não** altera sozinho (apenas reporta como `ERRO`): `AllowTcpForwarding no`, `DisableForwarding yes`, `AllowUsers` e `AllowGroups` que não incluam o `tunel`. Isso indica um servidor endurecido de propósito, e a decisão é sua.

## Fluxo por celular

1. **Preparar o aparelho** (parte manual, feita por quem estiver com ele):
   1. Instalar **Termux** e **Termux:Boot** pelo F-Droid.
   2. Abrir o Termux uma vez (espere aparecer `~ $`) e abrir o Termux:Boot uma vez.
   3. Bateria: Termux e Termux:Boot em **Sem restrições**.
   4. **Wi-Fi desligado** (e "Ativar Wi-Fi automaticamente" desligado). Com Wi-Fi ligado o tráfego sai pelo IP da rede local e o proxy perde o sentido.
   5. Dados móveis ligados no chip certo (em celular dual SIM, só um chip usa dados por vez).
   6. Economia de dados desligada, aparelho na tomada.
2. **Na VPS:**
   ```bash
   proxy4g novo 0
   cat /opt/celulares/bloco-cel0.txt
   ```
3. **Enviar o bloco** (uma linha só) ao celular e colar no Termux. Apagar a mensagem depois.
4. Aguardar ~2 a 5 minutos. O instalador termina com `RESULTADO: TUNEL ATIVO`. Sair pelo botão Home, sem digitar `exit`.
5. **Validar na VPS:**
   ```bash
   proxy4g validar 0
   ```
6. **Configurar a instância na Evolution** (antes de ler o QR code). Exemplo (confira o endpoint na sua versão):
   ```bash
   curl -X POST "https://URL_DA_EVOLUTION/proxy/set/NOME_DA_INSTANCIA" \
     -H "apikey: SUA_APIKEY" -H "Content-Type: application/json" \
     -d '{"enabled":true,"host":"BIND","port":"1080","protocol":"socks5","username":"","password":""}'
   ```
   `BIND` e a porta (`1080+N`) saem no final do `proxy4g validar N`.
7. **Teste de ausência de fallback:** no celular, `pkill -f tunel@`. A instância tem que perder a conexão. Se continuar online, ela não está usando o proxy.

Numeração: celular `N` usa a porta `1080+N` (ex.: celular 0 → 1080, celular 1 → 1081).

## Teste de reinício

1. Reinicie o celular e, se tiver PIN, destrave uma vez.
2. Espere ~2 minutos e rode `proxy4g validar N`.
3. Se não voltar: Termux:Boot não foi aberto, a bateria está restrita, ou o Termux não veio do F-Droid.

Com bloqueio de tela, o Android normalmente só roda os apps depois da primeira destravada. Em aparelhos que precisam subir sozinhos, avalie remover o bloqueio de tela.

## Segurança

- O bloco do celular contém a **chave privada** daquele aparelho. Ela só autoriza abrir a porta `1080+N`, sem shell (`restrict`, `permitlisten`, `command="/bin/false"`), e pode ser revogada com `proxy4g revogar N`.
- Envie o bloco por canal privado e apague depois. Evite grupos.
- O proxy não tem usuário e senha. Em Docker Swarm, qualquer container da rede alcança `BIND:1080+N`. Se houver outros serviços na VPS, restrinja por firewall.
- Configure o firewall para impedir que a Evolution saia pelo IP da VPS se o túnel cair. O script não faz isso.
- A verificação do host SSH é fixada (`StrictHostKeyChecking=yes` com a chave `ed25519` do servidor embutida no bloco).

## Arquivos

| Caminho | Conteúdo |
|---|---|
| `/usr/local/bin/proxy4g` | O script. |
| `/etc/celulares.conf` | `IP`, `SP` (porta SSH), `BIND`. |
| `/etc/ssh/sshd_config.d/10-tunel.conf` | Configuração do `sshd` gerada pelo script. |
| `/opt/celulares/celN`, `celN.pub` | Chave do celular `N` (privada só no root). |
| `/opt/celulares/bloco-celN.txt` | Bloco para colar no Termux. |
| `/opt/celulares/revogados/` | Chaves arquivadas pelo `revogar`. |
| `/root/backup-proxy4g-*` | Backup de arquivos alterados pelo `check`. |
| `~/tunel.log` (no celular) | Log do túnel. |

## Solução de problemas

| Sintoma | Causa provável |
|---|---|
| `check` mostra `AllowUsers`/`AllowTcpForwarding` como erro | Servidor endurecido. Ajuste manualmente o `sshd_config` (ex.: `Match User tunel`). |
| Bloco falha com `ERRO: bloco incompleto` | Colagem cortada. Copie a mensagem inteira e cole de novo. |
| Instalador falha em `1/5` ou `2/5` | Espelho do Termux ruim: `termux-change-repo` → *Single mirror*. |
| `TUNEL FALHOU` no celular | Veja `~/tunel.log`. `Permission denied (publickey)`: chave não autorizada, rode `proxy4g novo N` de novo. `remote port forwarding failed`: sessão antiga segurando a porta, aguarde ~90 s. |
| `validar`: túnel não conectado | Bloco não rodou, Termux foi fechado, celular sem dados, ou `fail2ban` baniu o IP. |
| `validar`: IP igual ao da VPS ou de datacenter | Wi-Fi do celular ligado ou proxy não está usando o 4G. |
| `validar`: container não alcança o proxy | Firewall (ufw/iptables) ou `BIND` errado. Rode `proxy4g check`. |
| IP muda durante o teste | A operadora reatribuiu o IP (CGNAT). Normal; o monitor de IP deve alertar e reconectar de forma escalonada. |
| Túnel morre sozinho (Android 12+) | O Android encerrou processos do Termux. Desative a restrição de processos filhos nas opções do desenvolvedor, quando existir. |

## Limitações conhecidas

- Sem acesso remoto ao celular (decisão de projeto).
- Cada reinício com PIN pode exigir uma destravada.
- O IP móvel muda quando a operadora reconecta; a validação mede, mas não corrige.
- 3 a 4 instâncias por IP móvel não foi provado como seguro; comece com cota menor e suba por gate.
- Pensado para Debian/Ubuntu (usa `apt-get`, `adduser`, `systemctl`).

## Licença

Defina a licença do repositório (ex.: MIT) antes de publicar.
#   S e t u p - d e - V P S - p a r a - c o n f i g u r a r - p r o x y - 4 g - m - v e l - e m - c e l u l a r  
 