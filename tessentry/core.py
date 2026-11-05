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

def send(cfg,folder,video,meta):
    """OpenWA WAHA-compatible API endpoint; confirm actual server contract in UI before enabling."""
    from urllib.parse import quote, urlsplit
    base=cfg['openwa_url'].rstrip('/')
    u=urlsplit(base)
    if u.scheme not in ('http','https') or not u.hostname or u.username or u.password: raise ValueError('Invalid OpenWA URL')
    # Require Tailscale host by default; LAN use requires explicit opt-in.
    if not cfg['allow_non_tailnet']:
        import ipaddress
        try:
            ip=ipaddress.ip_address(u.hostname)
            if not (ip.version==4 and ip in ipaddress.ip_network('100.64.0.0/10')): raise ValueError('OpenWA URL must be a Tailscale IP')
        except ValueError as e:
            if str(e)=='OpenWA URL must be a Tailscale IP': raise
            raise ValueError('Use a Tailscale IPv4 address or enable LAN override')
    session=quote(cfg['openwa_session'],safe='')
    chat=cfg['openwa_chat_id']
    headers={'X-Api-Key':cfg['openwa_api_key']}
    # These endpoints are based on common OpenWA/WAHA conventions and MUST be validated against deployed server.
    if cfg['send_text']:
        body=json.dumps({'chatId':chat,'text':event_text(folder,meta)}).encode()
        req=urllib.request.Request(f'{base}/api/sessions/{session}/messages/send-text',body,{**headers,'Content-Type':'application/json'},method='POST')
        with urllib.request.urlopen(req,timeout=30) as resp: resp.read()
    if cfg['send_video']:
        boundary='----Tessentry'+uuid.uuid4().hex
        def field(k,v): return (f'--{boundary}\r\nContent-Disposition: form-data; name="{k}"\r\n\r\n{v}\r\n').encode()
        payload=field('chatId',chat)+field('caption','Tesla Sentry event')
        payload+=(f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="event.mp4"\r\nContent-Type: video/mp4\r\n\r\n').encode()+video.read_bytes()+b'\r\n'+f'--{boundary}--\r\n'.encode()
        req=urllib.request.Request(f'{base}/api/sessions/{session}/messages/send-file',payload,{**headers,'Content-Type':'multipart/form-data; boundary='+boundary},method='POST')
        with urllib.request.urlopen(req,timeout=90) as resp: resp.read()

def scan_once():
    cfg=config()
    if not cfg['enabled']: return
    if not (cfg['openwa_url'] and cfg['openwa_api_key'] and cfg['openwa_session'] and cfg['openwa_chat_id']): return
    c=db()
    try:
        for key,folder,video,meta in discover(cfg):
            row=c.execute('SELECT status,attempts,updated FROM events WHERE id=?',(key,)).fetchone()
            if row and row[0] in ('sent','sending'): continue
            if row and (row[1]>=10 or (row[2] and time.time()-row[2]<min(3600,60*2**min(row[1],6)))): continue
            attempts=(row[1] if row else 0)+1
            # A pending state is persisted before delivery to avoid duplicate sends on restart.
            # On an interrupted delivery, manual review is needed; do not automatically retry uncertain sends.
            c.execute('INSERT OR REPLACE INTO events VALUES (?,?,?,?,?,?)',(key,str(folder),'sending',attempts,'',int(time.time())));c.commit()
            try:
                send(cfg,folder,video,meta)
                c.execute('UPDATE events SET status=?,error=?,updated=? WHERE id=?',('sent','',int(time.time()),key));c.commit()
                LOG.info('Sent event %s',folder)
            except Exception as e:
                c.execute('UPDATE events SET status=?,error=?,updated=? WHERE id=?',('failed',str(e)[:300],int(time.time()),key));c.commit()
                LOG.exception('Delivery failed: %s',folder)
    finally: c.close()

def worker():
    logging.basicConfig(level=logging.INFO,format='%(asctime)s %(levelname)s %(message)s')
    LOG.info('Tessentry worker started')
    while True:
        try: scan_once()
        except Exception: LOG.exception('Scan failed')
        time.sleep(max(10,min(3600,int(config()['scan_interval_seconds']))))
