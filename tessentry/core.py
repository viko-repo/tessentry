"""Tessentry event scanning and delivery; standard library only."""
import json, os, time, sqlite3, hashlib, urllib.request, urllib.error, mimetypes, uuid, logging
from pathlib import Path

BASE=Path(os.environ.get('TESSENTRY_DATA','/mutable/tessentry'))
DEFAULTS={'enabled':False,'scan_interval_seconds':30,'settle_seconds':90,'folders':['/mutable/TeslaCam/SentryClips','/mutable/TeslaCam/SavedClips'],'openwa_url':'','openwa_api_key':'','openwa_session':'','openwa_chat_id':'','send_video':True,'send_text':True,'allow_non_tailnet':False}
LOG=logging.getLogger('tessentry')

def config():
    d=dict(DEFAULTS)
    f=BASE/'config.json'
    if f.exists():
        try:
            x=json.loads(f.read_text()); d.update({k:v for k,v in x.items() if k in DEFAULTS})
        except (OSError,ValueError): LOG.exception('Invalid config')
    return d

def save_config(d):
    BASE.mkdir(parents=True,exist_ok=True)
    f=BASE/'config.json'; tmp=BASE/'config.json.tmp'
    tmp.write_text(json.dumps(d,indent=2,ensure_ascii=False)); os.chmod(tmp,0o600); os.replace(tmp,f)

def db():
    BASE.mkdir(parents=True,exist_ok=True)
    c=sqlite3.connect(BASE/'events.sqlite',timeout=20)
    c.execute('CREATE TABLE IF NOT EXISTS events (id TEXT PRIMARY KEY, path TEXT, status TEXT, attempts INTEGER DEFAULT 0, error TEXT, updated INTEGER)')
    cols={r[1] for r in c.execute('PRAGMA table_info(events)')}
    for name in ('text_sent','video_sent'):
        if name not in cols: c.execute(f'ALTER TABLE events ADD COLUMN {name} INTEGER NOT NULL DEFAULT 0')
    c.commit(); return c

def status():
    c=db()
    counts=dict(c.execute('SELECT status,count(*) FROM events GROUP BY status').fetchall()); c.close()
    return {'counts':counts,'folders':[{ 'path':str(f),'exists':Path(f).is_dir()} for f in config()['folders']], 'timestamp':int(time.time())}

def stable(path,seconds):
    try:
        s=path.stat()
        return s.st_size>0 and time.time()-s.st_mtime>=seconds
    except OSError: return False

def discover(cfg):
    for root in cfg['folders']:
        root=Path(root)
        if not root.is_dir(): continue
        try: dirs=list(root.iterdir())
        except OSError: continue
        for folder in dirs:
            if not folder.is_dir(): continue
            video=folder/'event.mp4'; meta=folder/'event.json'
            if not video.is_file() or not stable(video,cfg['settle_seconds']): continue
            if meta.exists() and not stable(meta,cfg['settle_seconds']): continue
            # Directory identity persists across restarts; do not resend on every scan.
            key=hashlib.sha256(str(folder.resolve()).encode()).hexdigest()
            yield key,folder,video,meta

def event_text(folder,meta):
    try: data=json.loads(meta.read_text()) if meta.exists() else {}
    except (OSError,ValueError): data={}
    cameras={'0':'Front','5':'Left fender (driver)','6':'Right fender (passenger)'}
    lines=['🚗 Tesla Sentry event',f'Folder: {folder.name}']
    for key,label in [('timestamp','Time'),('reason','Reason')]:
        if data.get(key): lines.append(f'{label}: {data[key]}')
    if data.get('camera') is not None: lines.append('Camera: '+cameras.get(str(data['camera']),str(data['camera'])))
    loc=', '.join(str(data[k]) for k in ('street','city') if data.get(k))
    if loc: lines.append('Location: '+loc)
    if data.get('est_lat') is not None and data.get('est_lon') is not None:
        try:
            lat=float(data['est_lat']); lon=float(data['est_lon'])
            if -90<=lat<=90 and -180<=lon<=180: lines.append(f'Map (approx.): https://maps.google.com/?q={lat},{lon}')
        except (TypeError,ValueError): pass
    return '\n'.join(lines)

def validate_openwa_url(cfg):
    """Reject non-Tailnet destinations unless explicitly permitted."""
    import ipaddress
    from urllib.parse import urlsplit
    u=urlsplit(cfg['openwa_url'].rstrip('/'))
    if u.scheme not in ('http','https') or not u.hostname or u.username or u.password or u.query or u.fragment:
        raise ValueError('Invalid OpenWA URL')
    if not cfg['allow_non_tailnet']:
        try: ip=ipaddress.ip_address(u.hostname)
        except ValueError: raise ValueError('Use a numeric Tailscale IPv4 address')
        if ip.version!=4 or ip not in ipaddress.ip_network('100.64.0.0/10'):
            raise ValueError('OpenWA URL must be a Tailscale IPv4 address')
    return cfg['openwa_url'].rstrip('/')

def send_part(cfg,folder,video,meta,part):
    """PREVIEW adapter: API route and payload MUST be validated before enabling."""
    from urllib.parse import quote
    base=validate_openwa_url(cfg)
    session=quote(cfg['openwa_session'],safe='')
    chat=cfg['openwa_chat_id']
    headers={'X-Api-Key':cfg['openwa_api_key']}
    if part=='text':
        body=json.dumps({'chatId':chat,'text':event_text(folder,meta)}).encode()
        req=urllib.request.Request(f'{base}/api/sessions/{session}/messages/send-text',body,{**headers,'Content-Type':'application/json'},method='POST')
        with urllib.request.urlopen(req,timeout=30) as resp: resp.read()
    elif part=='video':
        import base64
        body=json.dumps({
            'chatId':chat,
            'base64':base64.b64encode(video.read_bytes()).decode('ascii'),
            'mimetype':'video/mp4',
            'filename':'event.mp4',
            'caption':'Tesla Sentry event'
        }).encode()
        req=urllib.request.Request(f'{base}/api/sessions/{session}/messages/send-video',body,{**headers,'Content-Type':'application/json'},method='POST')
        with urllib.request.urlopen(req,timeout=90) as resp: resp.read()
    else: raise ValueError('Unknown message part')

def scan_once():
    cfg=config()
    if not cfg['enabled']: return
    if not (cfg['openwa_url'] and cfg['openwa_api_key'] and cfg['openwa_session'] and cfg['openwa_chat_id']): return
    c=db()
    try:
        for key,folder,video,meta in discover(cfg):
            row=c.execute('SELECT status,attempts,updated,text_sent,video_sent FROM events WHERE id=?',(key,)).fetchone()
            if row and row[0] in ('sent','sending','review'): continue
            if row and (row[1]>=10 or (row[2] and time.time()-row[2]<min(3600,60*2**min(row[1],6)))): continue
            attempts=(row[1] if row else 0)+1
            text_done=bool(row[3]) if row else False
            video_done=bool(row[4]) if row else False
            # Persist 'sending' before any external request. Interrupted calls are
            # uncertain and require manual review rather than automatic replay.
            c.execute('INSERT OR REPLACE INTO events (id,path,status,attempts,error,updated,text_sent,video_sent) VALUES (?,?,?,?,?,?,?,?)',
                      (key,str(folder),'sending',attempts,'',int(time.time()),int(text_done),int(video_done)))
            c.commit()
            try:
                for part,enabled,done in (('text',cfg['send_text'],text_done),('video',cfg['send_video'],video_done)):
                    if enabled and not done:
                        send_part(cfg,folder,video,meta,part)
                        c.execute(f'UPDATE events SET {part}_sent=1,updated=? WHERE id=?',(int(time.time()),key)); c.commit()
                c.execute('UPDATE events SET status=?,error=?,updated=? WHERE id=?',('sent','',int(time.time()),key));c.commit()
                LOG.info('Sent event %s',folder)
            except Exception as e:
                # Request may have been accepted remotely despite timeout. Hold for
                # review instead of automatically retrying an uncertain delivery.
                c.execute('UPDATE events SET status=?,error=?,updated=? WHERE id=?',('review',str(e)[:300],int(time.time()),key));c.commit()
                LOG.exception('Delivery needs review: %s',folder)
    finally: c.close()

def worker():
    logging.basicConfig(level=logging.INFO,format='%(asctime)s %(levelname)s %(message)s')
    LOG.info('Tessentry worker started')
    while True:
        try: scan_once()
        except Exception: LOG.exception('Scan failed')
        time.sleep(max(10,min(3600,int(config()['scan_interval_seconds']))))
