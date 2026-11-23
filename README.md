# termux-battery-watch

Monitoramento de bateria de dispositivos **Android** pelo **Termux**, com alertas enviados ao **WhatsApp** por uma instância da **Evolution API v2**.

Funciona **sem root** e **sem cron**. Usa preferencialmente o aplicativo **Termux:API** para consultar a bateria, com tentativa alternativa de leitura por `/sys/class/power_supply` quando o Android permite. O monitor funciona independentemente de gateways de agentes ou serviços como Hermes.

## Alertas

| Evento | Condição inicial padrão | Comportamento |
| --- | --- | --- |
| Bateria baixa | **30% ou menos**, desconectado ou sem alimentação confirmada | Avisa uma vez; rearma acima de **33%** |
| Carregador conectado | Transição para fonte de energia conectada, antes de 100% | Avisa uma vez por conexão |
| Carga completa | **100%** | Avisa uma vez; rearma abaixo de **98%** |

A verificação ocorre a cada **60 segundos** (configurável). Ao iniciar o monitor com o carregador já conectado ou a carga já completa, esses dois avisos de transição são silenciados. **Bateria baixa** pode gerar aviso imediatamente, incluindo quando a origem da alimentação é desconhecida (mensagem neutra). Um estado `NOT_CHARGING` não significa automaticamente que o cabo esteja desconectado.

> **Importante:** o projeto depende de uma Evolution API acessível e de uma instância WhatsApp conectada. O sucesso HTTP confirma que a requisição foi aceita pela API, **não** comprova a entrega ao destinatário.

## 1. Pré-requisitos: aplicativos Android

Instale pelo **F-Droid**:

1. [Termux](https://f-droid.org/packages/com.termux/) — aplicativo do terminal.
2. [Termux:API](https://f-droid.org/packages/com.termux.api/) — complemento Android que permite consultar o nível e o estado da bateria.
3. [Termux:Boot](https://f-droid.org/packages/com.termux.boot/) — **opcional**, para iniciar o monitor após reiniciar o aparelho.

**São dois componentes diferentes com nomes parecidos:** o aplicativo **Termux:API** deve ser instalado no Android; além dele, é preciso instalar o **pacote** `termux-api` **dentro do terminal**.

**Não misture fontes de instalação:** Termux e seus complementos devem ter assinaturas compatíveis (por exemplo, todos provenientes do F-Droid). A versão da Play Store voltou a receber atualizações, mas pertence a uma distribuição diferente e pode não ser compatível com os complementos usados aqui. Consulte as [orientações oficiais do Termux](https://github.com/termux/termux-app#installation).

**Samsung Galaxy:** se a instalação pelo F-Droid exibir **"Aplicativo desconhecido bloqueado"**, acesse **Configurações → Segurança e privacidade → Bloqueador automático** e desative-o **temporariamente**, apenas durante a instalação do Termux, Termux:API e Termux:Boot provenientes do F-Droid. Depois, **reative o Bloqueador automático**. A instalação de futuras atualizações externas poderá exigir nova desativação temporária. Os nomes das opções variam conforme a versão do One UI.

## 2. Instalar os pacotes no Termux

Abra o **Termux** e execute:

```bash
pkg update && pkg upgrade -y
pkg install curl jq coreutils util-linux termux-api -y
```

| Pacote | Utilização |
| --- | --- |
| `curl` | Envio HTTPS para a Evolution API |
| `jq` | Leitura do JSON da bateria e montagem segura da mensagem |
| `coreutils` | `timeout` para evitar bloqueio de comandos |
| `util-linux` | `flock` para impedir processos duplicados |
| `termux-api` | Comando `termux-battery-status`, que conversa com o aplicativo Termux:API |

O Python, Git e Wget **não são dependências de execução** do monitor; não é preciso removê-los se você já os instalou. O Git é útil para clonar ou atualizar o projeto.

Teste a leitura:

```bash
timeout 10s termux-battery-status
```

A saída deve ser um JSON com `percentage`, `status` e `plugged`, por exemplo:

```json
{
  "percentage": 47,
  "status": "DISCHARGING",
  "plugged": "UNPLUGGED"
}
```

*Exemplo ilustrativo: a saída real possui outros campos.*

Se o comando travar, confirme que o **aplicativo Android Termux:API** também está instalado e que Termux e Termux:API vieram da mesma fonte. O script utiliza `timeout` para não ficar bloqueado indefinidamente.

## 3. Instalar o monitor

Clone seu repositório após publicá-lo, ou copie os arquivos para o celular:

```bash
# Repositório oficial da BrLink
pkg install git -y
git clone https://github.com/brlink-org/termux-battery-watch.git
cd termux-battery-watch

mkdir -p "$HOME/bin"
install -m 700 battery-watch.sh "$HOME/bin/battery-watch.sh"
install -m 600 battery-watch.conf.example "$HOME/.battery-watch.conf"
nano "$HOME/.battery-watch.conf"
```

Se preferir copiar os arquivos pela pasta Downloads, conceda acesso com `termux-setup-storage` e copie `battery-watch.sh` e `battery-watch.conf.example` para o diretório privado do Termux.

### Configuração

Edite `~/.battery-watch.conf`:

```bash
EVO_URL="https://sua-evolution.exemplo.com"
EVO_TOKEN="SUA_CHAVE_API"
EVO_INSTANCE="nome_da_instancia"
DESTINO="5571999999999"

INTERVALO=60
LIMIAR_BAIXO=30
LIMIAR_RESET=33
LIMIAR_CHEIO=100
LIMIAR_CHEIO_RESET=98
```

- `EVO_URL`: URL base da Evolution API. **HTTPS obrigatório** para servidores externos. HTTP só é aceito em loopback (`127.0.0.1`, `localhost` ou `[::1]`), com `BATWATCH_ALLOW_HTTP_LOOPBACK=1` para testes locais.
- `EVO_TOKEN`: chave de API autorizada para envio de mensagens (`apikey`).
- `EVO_INSTANCE`: nome da instância conectada. Nomes com espaços e Unicode são codificados com segurança na URL; separadores de caminho (`/`, `?`, `#`, `%`) e caracteres de controle são rejeitados antes do envio.
- `DESTINO`: número internacional apenas com dígitos, por exemplo `55` + DDD + número do celular.
- `INTERVALO`: intervalo entre leituras em segundos.
- Limiares: percentuais configuráveis e seus pontos de rearme (**histerese**).

Proteja a configuração:

```bash
chmod 600 ~/.battery-watch.conf
```

**Nunca envie a configuração preenchida ao GitHub, a terceiros ou a capturas de tela.** O projeto inclui `.gitignore` para evitar commits acidentais do `battery-watch.conf`.

## 4. Testar com segurança

Primeiro, consulte a bateria **sem enviar mensagens**:

```bash
~/bin/battery-watch.sh --status
```

A saída será semelhante a:

```text
Bateria: 47% | status: DISCHARGING | fonte: UNPLUGGED
```

Depois teste a lógica dos eventos sem chamadas HTTP:

```bash
DRY=1 ~/bin/battery-watch.sh
```

O modo `DRY=1` **não executa `curl`** e usa `~/.battery-watch.state.dry` e `~/.battery-watch.lock.dry`, separados dos arquivos de produção. Se o aparelho estiver acima de 30% e não houver transição de carregamento, nenhum alerta aparecerá imediatamente: isso é esperado. Para testar, provoque uma transição real conectando ou desconectando o carregador, ou ajuste os limiares para um teste controlado.

Em outra sessão do Termux, acompanhe:

```bash
tail -f ~/.battery-watch.log
```

Interrompa o teste com **Ctrl+C**. O estado de teste pode ser zerado com `rm ~/.battery-watch.state.dry` após parar o processo.

## 5. Executar em produção

Com a Evolution API e o destino configurados, execute:

```bash
~/bin/battery-watch.sh
```

Para manter em segundo plano:

```bash
nohup "$HOME/bin/battery-watch.sh" >> "$HOME/.battery-watch.log" 2>&1 &
```

O script solicita `termux-wake-lock`, faz a leitura periodicamente e usa `flock` para impedir duas instâncias simultâneas. **Não é necessário executar `termux-wake-lock` separadamente** para esse monitor.

Para observar e encerrar:

```bash
tail -f ~/.battery-watch.log
pgrep -af battery-watch.sh
pkill -f battery-watch.sh
```

O encerramento não libera necessariamente outros wake locks que eventualmente estejam ativos no Termux. Use `termux-wake-unlock` apenas quando souber que não há outros processos dependendo dessa proteção.

## 6. Iniciar automaticamente ao ligar o Android (opcional)

Instale [Termux:Boot pelo F-Droid](https://f-droid.org/packages/com.termux.boot/) **da mesma fonte que o Termux** e **abra o aplicativo Termux:Boot uma vez**. A abertura inicial é exigida pelo projeto oficial para habilitar sua inicialização automática.

No terminal:

```bash
mkdir -p ~/.termux/boot
cat > ~/.termux/boot/start-battery-watch <<'SCRIPT'
#!/data/data/com.termux/files/usr/bin/sh
sleep 20
nohup "$HOME/bin/battery-watch.sh" >> "$HOME/.battery-watch.log" 2>&1 &
SCRIPT
chmod 700 ~/.termux/boot/start-battery-watch
```

O `flock` evita que o monitor iniciado automaticamente duplique um monitor já em execução.

Para reduzir interrupções pelo Android, considere nas configurações do aparelho:

- **Termux → Bateria → Sem restrições**.
- **Termux:API → Bateria → Sem restrições**.
- **Termux:Boot → Bateria → Sem restrições**, se estiver utilizando o boot automático.
- Permitir as notificações necessárias do Termux e, nos Samsung, adicionar os aplicativos à lista de **nunca suspensos**, quando disponível.

**Limitação:** as políticas de economia de energia do Android, especialmente de alguns fabricantes, ainda podem suspender ou encerrar processos. O wake lock consome energia adicional e **não garante** execução permanente.

## 7. Diagnóstico e arquivos locais

| Arquivo | Finalidade |
| --- | --- |
| `~/.battery-watch.conf` | Configuração privada contendo o token da Evolution |
| `~/.battery-watch.curlrc` | Cabeçalhos privados do `curl`; regenerado a cada execução em produção |
| `~/.battery-watch.state` | Estado dos alertas de produção |
| `~/.battery-watch.state.dry` | Estado isolado dos testes |
| `~/.battery-watch.lock.dry` | Bloqueio isolado de processos em modo de teste |
| `~/.battery-watch.log` | Histórico das ações e falhas |
| `~/.battery-watch.lock` | Bloqueio contra monitores simultâneos |

Arquivos que contêm dados de configuração e credenciais são gravados com permissões restritas (`600`) no diretório privado do Termux.

### `termux-battery-status` não retorna dados

```bash
timeout 10s termux-battery-status
~/bin/battery-watch.sh --status
```

Se o aplicativo Termux:API e o pacote `termux-api` estiverem instalados, mas o comando falhar, verifique as permissões e restrições de bateria. Como contingência, o script tenta a leitura de `/sys/class/power_supply`, mas o acesso depende do Android e do fabricante.

### Não recebi nenhum WhatsApp

Verifique se `DRY=1` não está ativo, se os dados da API estão corretos, se a instância WhatsApp está conectada e se ocorreu algum evento que justificasse o alerta. Consulte o log:

```bash
tail -n 50 ~/.battery-watch.log
```

O monitor **não envia uma mensagem apenas porque foi iniciado**, exceto aviso de bateria baixa. Se o envio falhar, ele tenta novamente na próxima leitura, enquanto a condição persistir.

### Alterei o token da Evolution API

Reinicie o monitor. A versão atual regrava `~/.battery-watch.curlrc` com o token configurado a cada inicialização em produção.

### Quero redefinir os alertas

Pare o monitor antes de remover o estado, evitando alterações simultâneas:

```bash
pkill -f battery-watch.sh
rm -f ~/.battery-watch.state ~/.battery-watch.state.dry
```

Em seguida, inicie o monitor novamente.

## Segurança e limitações

- **Não publique tokens, números pessoais ou logs de produção** em issues ou commits.
- O arquivo `~/.battery-watch.conf` é interpretado como código Bash; edite somente configurações de origem confiável.
- Use uma instância Evolution em **HTTPS** e credenciais com acesso restrito. A opção de HTTP local existe somente para testes explicitamente autorizados.
- O token não é passado como argumento do processo `curl`; ele é gravado em `~/.battery-watch.curlrc` com permissão `600`. O comando utiliza `curl -q` para ignorar opções da configuração global `~/.curlrc` e não segue redirecionamentos automaticamente.
- Mensagens aceitas por HTTP **2xx** não representam garantia de entrega pelo WhatsApp.
- O monitor depende de bateria, conectividade, disponibilidade da API e políticas de execução em segundo plano do Android.
- O projeto **não é** um sistema de segurança ou alerta crítico com alta disponibilidade.

## Referências

- [Termux — instalação e compatibilidade entre fontes](https://github.com/termux/termux-app#installation)
- [Termux:API — projeto oficial](https://github.com/termux/termux-api)
- [Termux:API — implementação de bateria (`percentage`, `status`, `plugged`)](https://github.com/termux/termux-api/blob/master/app/src/main/java/com/termux/api/apis/BatteryStatusAPI.java)
- [Termux:Boot — instalação e inicialização](https://github.com/termux/termux-boot)
- [Evolution API — repositório oficial](https://github.com/evolution-foundation/evolution-api)

## Licença

Distribuído sob a [licença MIT](LICENSE).
