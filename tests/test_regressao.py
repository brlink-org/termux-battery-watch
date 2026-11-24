#!/usr/bin/env python3
"""Regressões determinísticas. Nenhum WhatsApp real; curl simulado ou loopback."""
import fcntl
import http.server
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = Path(os.environ.get('BATWATCH_TEST_SCRIPT', ROOT / 'battery-watch.sh')).resolve()
PYTHON = sys.executable
PHONE = '5511999999999'
GROUP = '5511999999999-1571774628@g.us'
MODERN = '120363000000000000@g.us'
TOKEN = 'chave_ficticia'


def leitura(cap=50, status='DISCHARGING', plugged='UNPLUGGED', **extra):
    return dict(percentage=cap, status=status, plugged=plugged, **extra)


class Monitor:
    def __init__(self, path):
        self.home = path
        self.bin = path / 'bin'
        self.bin.mkdir()
        self.env = dict(PATH=f'{self.bin}:{os.environ["PATH"]}', HOME=str(path),
                        LC_ALL='C.UTF-8', BATWATCH_CONF=str(path / 'conf'),
                        BATWATCH_SYSFS_ROOT=str(path / 'sysfs'), MOCK_HOME=str(path))
        self.conf = dict(EVO_URL='https://evo.example.invalid', EVO_TOKEN=TOKEN,
                         EVO_INSTANCE='cirinho', DESTINO=PHONE, INTERVALO='1')
        self.mock('termux-battery-status', '''import json, os, pathlib, sys
h=pathlib.Path(os.environ['MOCK_HOME']); n=int((h/'cycle').read_text())
rows=json.loads((h/'readings').read_text()); r=rows[min(n,len(rows)-1)]
if r.get('sysfs'):
    root=h/'sysfs'; b=root/'battery'; b.mkdir(parents=True,exist_ok=True)
    for k,v in {'type':'Battery','capacity':r['percentage'],'status':r['status']}.items():
        (b/k).write_text(str(v))
    a=root/'ac'; a.mkdir(exist_ok=True); (a/'type').write_text('Mains')
    if r.get('online') is None: (a/'online').unlink(missing_ok=True)
    else: (a/'online').write_text(str(r['online']))
    sys.exit(1)
if r.get('fail'): sys.exit(1)
print(json.dumps(r))
''')
        self.mock('sleep', '''import json,os,pathlib,signal
h=pathlib.Path(os.environ['MOCK_HOME']); p=h/'cycle'; n=int(p.read_text())+1; p.write_text(str(n))
if n>=int(os.environ['MOCK_LIMIT']): os.kill(os.getppid(),signal.SIGTERM)
''')
        self.mock('termux-wake-lock', 'pass\n')
        self.mock('curl', '''import json,os,pathlib,sys
h=pathlib.Path(os.environ['MOCK_HOME']); a=sys.argv[1:]
def opt(k): return a[a.index(k)+1]
try:
    assert a[0]=='-q' and '-L' not in a and '--location' not in a
    assert opt('--proto')=='=https' and opt('--proto-redir')=='=https' and opt('--max-redirs')=='0'
    assert opt('-X')=='POST' and a[a.index('-X')+2]==os.environ['MOCK_URL']
    assert opt('-w')=='%{http_code}' and opt('-o')=='/dev/null'
    assert pathlib.Path(opt('-K')).read_text() == 'header = "apikey: '+os.environ['MOCK_TOKEN']+'"\\nheader = "Content-Type: application/json"\\n'
    data=json.loads(opt('--data-binary')); assert set(data)=={'number','text'} and data['number']==os.environ['MOCK_DEST']
    assert isinstance(data['text'],str)
except Exception as e:
    (h/'mock_error').write_text(repr(e)); sys.exit(97)
with (h/'calls').open('a') as f: f.write(json.dumps(data,ensure_ascii=False)+'\\n')
if int(os.environ['MOCK_RC']): print('simulated private detail '+os.environ['MOCK_TOKEN'],file=sys.stderr)
print(os.environ['MOCK_HTTP'],end=''); sys.exit(int(os.environ['MOCK_RC']))
''')
        # Conta substituições atômicas do state sem depender de strace.
        mv = shutil.which('mv')
        self.mock('mv', f'''import os,pathlib,sys
h=pathlib.Path(os.environ['MOCK_HOME']); a=sys.argv[1:]
if a[-1].endswith(('.state','.state.dry')):
    with (h/'writes').open('a') as f: f.write('1\\n')
    if os.environ.get('MOCK_FAIL_WRITE')=='1': sys.exit(1)
os.execv({mv!r},[{mv!r},*a])
''')

    def mock(self, name, body):
        p = self.bin / name
        p.write_text('#!' + PYTHON + '\n' + body)
        p.chmod(0o700)

    def run(self, rows, *, dry=False, http='201', rc=0, expected=None, extra=None, args=(), nohup=False):
        (self.home / 'cycle').write_text('0')
        (self.home / 'readings').write_text(json.dumps(rows))
        (self.home / 'conf').write_text(''.join(f'{k}={shlex.quote(str(v))}\n' for k,v in self.conf.items()))
        from urllib.parse import quote
        env = self.env | dict(DRY=str(int(dry)), MOCK_LIMIT=str(len(rows)), MOCK_HTTP=http, MOCK_RC=str(rc),
                              MOCK_URL=self.conf['EVO_URL'].rstrip('/')+'/message/sendText/'+quote(self.conf['EVO_INSTANCE'],safe=''),
                              MOCK_DEST=self.conf['DESTINO'], MOCK_TOKEN=self.conf['EVO_TOKEN']) | (extra or {})
        cmd = ['bash', str(SCRIPT), *args]
        if nohup:
            p = subprocess.run(['nohup', *cmd], env=env, cwd=self.home, stdin=subprocess.DEVNULL,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, text=True, timeout=20)
        else:
            p = subprocess.run(cmd, env=env, capture_output=True, text=True, timeout=20)
        wanted = (-15,143) if expected is None else (expected,)
        if p.returncode not in wanted:
            raise AssertionError(f'exit {p.returncode}, esperado {wanted}; stderr={p.stderr!r}, stdout={p.stdout!r}')
        if expected is None and int((self.home/'cycle').read_text()) != len(rows):
            raise AssertionError('monitor não completou todos os ciclos')
        if (self.home/'mock_error').exists(): raise AssertionError((self.home/'mock_error').read_text())
        return p

    def calls(self):
        p=self.home/'calls'; return [json.loads(x) for x in p.read_text().splitlines()] if p.exists() else []

    def log(self, dry=False):
        p=self.home/('.battery-watch.log'+('.dry' if dry else '')); return p.read_text() if p.exists() else ''

    def state(self, dry=False):
        p=self.home/('.battery-watch.state'+('.dry' if dry else '')); return dict(x.split('=',1) for x in p.read_text().splitlines())


class Regressao(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.m=Monitor(Path(self.tmp.name))

    def test_api_baixa_indeterminada(self):
        self.m.run([leitura(20,'NOT_CHARGING','UNKNOWN')]*3)
        self.assertEqual(len(self.m.calls()),1); self.assertIn('Nao foi possivel confirmar',self.m.calls()[0]['text'])

    def test_api_plugged_menos_um(self):
        self.m.run([leitura(20,'DISCHARGING','PLUGGED_-1')]*2)
        self.assertEqual(len(self.m.calls()),1); self.assertIn('descarregando',self.m.calls()[0]['text'])

    def test_api_conectado_sem_carga(self):
        self.m.run([leitura(20,'NOT_CHARGING','PLUGGED_AC')]*2); self.assertEqual(self.m.calls(),[])

    def test_api_contraditorio(self):
        self.m.run([leitura(20,'DISCHARGING','PLUGGED_AC')]); self.assertIn('apesar da fonte conectada',self.m.calls()[0]['text'])

    def test_api_duas_conexoes_registros(self):
        a,b=leitura(),leitura(50,'CHARGING','PLUGGED_AC')
        self.m.run([a,b,a,b]); self.assertEqual(len(self.m.calls()),2); self.assertEqual(self.m.log().count('OK evento=plugado'),2)

    def test_api_indeterminado_nao_rearma(self):
        a=leitura(50,'CHARGING','PLUGGED_AC'); self.m.run([a,leitura(50,'NOT_CHARGING','UNKNOWN'),a]); self.assertEqual(self.m.calls(),[])

    def test_sysfs_explicito(self):
        a,b=leitura(50,'Discharging',sysfs=True,online=0),leitura(50,'Charging',sysfs=True,online=1)
        self.m.run([a,b,a,b]); self.assertEqual(len(self.m.calls()),2); self.assertIn('Carregador conectado',self.m.calls()[0]['text'])

    def test_sysfs_inferido(self):
        a,b=leitura(50,'Discharging',sysfs=True),leitura(50,'Charging',sysfs=True)
        self.m.run([a,b,a,b]); self.assertEqual(len(self.m.calls()),2); self.assertTrue(all('fonte inferida' in x['text'] for x in self.m.calls()))

    def test_sysfs_indeterminado(self):
        a,b=leitura(50,'Charging',sysfs=True),leitura(50,'Not charging',sysfs=True)
        self.m.run([a,b,a]); self.assertEqual(self.m.calls(),[])

    def test_sysfs_online_prevalece(self):
        a,b=leitura(50,'Charging',sysfs=True,online=1),leitura(50,'Discharging',sysfs=True,online=1)
        self.m.run([a,b,a]); self.assertEqual(self.m.calls(),[])

    def test_log_recuperacao(self):
        self.m.run([leitura(fail=True)]*3+[leitura()]); log=self.m.log()
        self.assertEqual(sum('leitura da bateria indisponivel' in x and 'RESUMO' not in x for x in log.splitlines()),1)
        self.assertIn('repetido 2 vezes',log); self.assertIn('leitura da bateria recuperada',log)

    def test_dry_isolado(self):
        self.m.run([leitura(20)]*2,dry=True); self.assertFalse((self.m.home/'.battery-watch.log').exists()); self.assertEqual(self.m.calls(),[]); self.assertIn('DRY evento=baixo',self.m.log(True))

    def test_rotacao(self):
        self.m.conf['BATWATCH_LOG_MAX_BYTES']='1024'
        for i in range(3):
            (self.m.home/'.battery-watch.log').write_text(str(i)*2000+'\n'); self.m.run([leitura()])
        self.assertEqual((self.m.home/'.battery-watch.log.1').read_text(), '2'*2000+'\n'); self.assertEqual((self.m.home/'.battery-watch.log.2').read_text(),'1'*2000+'\n')
        self.assertTrue(self.m.log())

    def test_401_reinicio_troca_token(self):
        rows=[leitura(20)]*3; self.m.run(rows,http='401'); self.assertEqual(len(self.m.calls()),1)
        self.assertEqual(self.m.state()['falhas_baixo'],'1'); self.m.run(rows,http='401'); self.assertEqual(len(self.m.calls()),1)
        self.m.conf['EVO_TOKEN']='outra_chave_ficticia'; self.m.run(rows); self.assertEqual(len(self.m.calls()),2); self.assertEqual(self.m.state()['baixo_avisado'],'1')

    def test_429_500_timeout_dns_tls(self):
        for i,(http,rc,espera,motivo) in enumerate([('429',0,900,'HTTP sem sucesso'),('500',0,60,'HTTP sem sucesso'),('000',28,900,'tempo limite'),('000',6,60,'DNS'),('000',7,60,'conexão'),('000',60,60,'TLS')]):
            with self.subTest(http=http,rc=rc):
                h=self.m.home/f'falha{i}'; h.mkdir(); m=Monitor(h); m.run([leitura(20)]*3,http=http,rc=rc)
                self.assertEqual(len(m.calls()),1); self.assertIn(f'espera={espera}s',m.log()); self.assertIn(motivo,m.log()); self.assertNotIn(TOKEN,m.log()); self.assertNotIn('baixo_avisado',m.state())
                if rc==28:self.assertIn('resultado incerto',m.log())

    def test_state_economia(self):
        self.m.run([leitura()]); p=self.m.home/'writes'; before=len(p.read_text().splitlines()); self.m.run([leitura()]*4)
        self.assertEqual(len(p.read_text().splitlines()),before)
        self.m.run([leitura(51)]); self.assertEqual(len(p.read_text().splitlines()),before+1)

    def test_state_normaliza_duplicatas(self):
        p=self.m.home/'.battery-watch.state'; p.write_text('baixo_avisado=1\nbaixo_avisado=0\nlixo\nultimo=50\n'); self.m.run([leitura()])
        self.assertEqual(p.read_text().count('baixo_avisado='),1); self.assertNotIn('lixo',p.read_text()); self.assertEqual(self.m.state()['baixo_avisado'],'0')

    def test_state_falha_escrita(self):
        p=self.m.run([leitura(20)],expected=2,extra={'MOCK_FAIL_WRITE':'1'}); self.assertIn('falha ao persistir estado',p.stderr); self.assertEqual(self.m.calls(),[])

    def test_grupos_e_contato(self):
        for i,dest in enumerate([PHONE,GROUP,MODERN]):
            with self.subTest(dest=dest):
                h=self.m.home/f'dest{i}'; h.mkdir(); m=Monitor(h); m.conf['DESTINO']=dest; m.run([leitura(20)])
                self.assertEqual(m.calls()[0]['number'],dest); self.assertEqual(len(m.calls()),1)

    def test_grupo_dry(self):
        self.m.conf['DESTINO']=GROUP; self.m.run([leitura(20)],dry=True); self.assertIn('DRY evento=baixo',self.m.log(True)); self.assertEqual(self.m.calls(),[])

    def test_destinos_invalidos(self):
        for dest in ['123','+5511999999999','123@g.us ','123--456@g.us','123@evil.com','abc@g.us','@g.us']:
            with self.subTest(dest=dest):
                self.m.conf['DESTINO']=dest; p=self.m.run([leitura(20)],expected=2); self.assertIn('DESTINO',p.stderr); self.assertEqual(self.m.calls(),[])

    def test_modelos_todos(self):
        cases=[('MSG_BAIXA_DESCONECTADO',[leitura(20)],20),('MSG_BAIXA_CONECTADO',[leitura(20,'DISCHARGING','PLUGGED_AC')],20),('MSG_BAIXA_DESCONHECIDO',[leitura(20,'NOT_CHARGING','UNKNOWN')],20),('MSG_CARREGADOR_CONECTADO',[leitura(),leitura(51,'CHARGING','PLUGGED_AC')],51),('MSG_CARGA_COMPLETA',[leitura(99),leitura(100,'FULL','PLUGGED_AC')],100),('MSG_CARREGADOR_INFERIDO',[leitura(sysfs=True),leitura(51,'Charging',sysfs=True)],51)]
        for i,(name,rows,cap) in enumerate(cases):
            with self.subTest(name=name):
                h=self.m.home/f'msg{i}';h.mkdir();m=Monitor(h)
                template='🔋 *{percentual}%* / {percentual} $HOME $(false) %s\nsegunda linha\n'; m.conf[name]=template; m.run(rows)
                self.assertEqual(len(m.calls()),1); self.assertEqual(m.calls()[0]['text'],template.replace('{percentual}',str(cap))); self.assertEqual(m.log().count('OK evento='),1); self.assertIn('\\nsegunda linha\\n',m.log())

    def test_modelo_dry(self):
        self.m.conf['MSG_BAIXA_DESCONECTADO']='Teste {percentual}%'; p=self.m.run([leitura(20)],dry=True); self.assertIn('[DRY] Teste 20%',p.stdout); self.assertEqual(self.m.calls(),[])

    def test_https_externo_e_instancia(self):
        self.m.conf['EVO_URL']='http://203.0.113.1'; p=self.m.run([leitura(20)],expected=2,extra={'BATWATCH_ALLOW_HTTP_LOOPBACK':'1'}); self.assertIn('HTTP e permitido apenas',p.stderr)
        self.m.conf['EVO_URL']='https://evo.example.invalid'; self.m.conf['EVO_INSTANCE']='a/b'; p=self.m.run([leitura(20)],expected=2); self.assertIn('EVO_INSTANCE',p.stderr); self.assertEqual(self.m.calls(),[])

    def test_unicode_instancia(self):
        self.m.conf['EVO_INSTANCE']='Loja São João'; self.m.run([leitura(20)]); self.assertEqual(len(self.m.calls()),1)

    def test_status_sem_escrita(self):
        p=self.m.run([leitura(47)],expected=0,args=('--status',)); self.assertIn('Bateria: 47% | status: DISCHARGING | fonte: UNPLUGGED',p.stdout); self.assertFalse((self.m.home/'.battery-watch.state').exists())

    def test_curl_real_loopback(self):
        recebidos=[]
        class H(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                recebidos.append((self.path,self.headers.get('apikey'),json.loads(self.rfile.read(int(self.headers['Content-Length'])))))
                self.send_response(201); self.end_headers()
            def log_message(self,*args):pass
        with http.server.HTTPServer(('127.0.0.1',0),H) as srv:
            t=threading.Thread(target=srv.serve_forever,daemon=True); t.start()
            try:
                (self.m.bin/'curl').unlink(); (self.m.home/'.curlrc').write_text('proxy = "http://127.0.0.1:1"\n')
                self.m.conf.update(EVO_URL=f'http://127.0.0.1:{srv.server_port}',DESTINO=GROUP)
                self.m.run([leitura(20)],extra={'BATWATCH_ALLOW_HTTP_LOOPBACK':'1'})
            finally:srv.shutdown();t.join()
        self.assertEqual(len(recebidos),1);self.assertEqual(recebidos[0][0],'/message/sendText/cirinho');self.assertEqual(recebidos[0][1],TOKEN);self.assertEqual(recebidos[0][2]['number'],GROUP)

    def test_histerese(self):
        self.m.run([leitura(n) for n in [31,30,29,33,30,34,30]])
        self.assertEqual(len(self.m.calls()),2); self.assertEqual(self.m.state()['baixo_avisado'],'1')

    def test_carga_completa_histerese(self):
        self.m.run([leitura(n,'CHARGING','PLUGGED_AC') for n in [99,100,99,98,100,97,100]])
        self.assertEqual(len(self.m.calls()),2); self.assertTrue(all('carga completa' in x['text'] for x in self.m.calls()))

    def test_backoff_progressivo(self):
        self.m.run([leitura(20)],http='500')
        p=self.m.home/'.battery-watch.state'
        for atraso in [120,240,300,300]:
            p.write_text('\n'.join('proxima_baixo=0' if x.startswith('proxima_baixo=') else x for x in p.read_text().splitlines())+'\n')
            self.m.run([leitura(20)]*2,http='500'); self.assertIn(f'espera={atraso}s',self.m.log())
        self.assertEqual(len(self.m.calls()),5)

    def test_nohup_rotacao(self):
        self.m.conf['BATWATCH_LOG_MAX_BYTES']='1024'
        (self.m.home/'.battery-watch.log').write_text('x'*2000+'\n')
        self.m.run([leitura(),leitura(50,'CHARGING','PLUGGED_AC')],nohup=True)
        self.assertTrue((self.m.home/'.battery-watch.log.1').exists()); self.assertIn('OK evento=plugado',self.m.log()); self.assertFalse((self.m.home/'nohup.out').exists())

    def test_bloqueio_concorrente(self):
        with (self.m.home/'.battery-watch.lock').open('w') as lock:
            fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
            p=self.m.run([leitura(20)],expected=2)
            self.assertIn('monitor ja esta em execucao',p.stderr); self.assertEqual(self.m.calls(),[])

    def test_gitignore(self):
        h=self.m.home/'repo';h.mkdir();shutil.copy(ROOT/'.gitignore',h/'.gitignore');subprocess.run(['git','init','-q',str(h)],check=True)
        p=subprocess.run(['git','-C',str(h),'check-ignore','.battery-watch.log','.battery-watch.log.dry','.battery-watch.log.1','.battery-watch.log.dry.2','.battery-watch.state.ABC','.battery-watch.state.dry.ABC','.battery-watch.lock.dry','.battery-watch.conf','.battery-watch.curlrc'],capture_output=True,text=True,check=True)
        self.assertEqual(len(p.stdout.splitlines()),9)
        p=subprocess.run(['git','-C',str(h),'check-ignore','battery-watch.sh','README.md','tests/test_regressao.py'],capture_output=True,text=True);self.assertEqual(p.returncode,1)

if __name__=='__main__': unittest.main(verbosity=2)
