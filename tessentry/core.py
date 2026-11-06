"""Tessentry event scanning and delivery; standard library only."""
import json, os, time, sqlite3, hashlib, urllib.request, urllib.error, mimetypes, uuid, logging
from pathlib import Path

BASE=Path(os.environ.get('TESSENTRY_DATA','/mutable/tessentry'))
DEFAULTS={'enabled':False,'scan_interval_seconds':30,'settle_seconds':90,'folders':['/mutable/TeslaCam/SentryClips','/mutable/TeslaCam/SavedClips'],'openwa_url':'','openwa_api_key':'','openwa_session':'','openwa_chat_id':'','send_video':True,'send_text':True,'notification_language':'en','allow_non_tailnet':False,'notification_provider':'whatsapp','telegram_bot_token':'','telegram_chat_id':''}
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
    for name in ('text_sent','video_sent','location_sent'):
        if name not in cols: c.execute(f'ALTER TABLE events ADD COLUMN {name} INTEGER NOT NULL DEFAULT 0')
    c.execute('CREATE TABLE IF NOT EXISTS deliveries (event_id TEXT NOT NULL, provider TEXT NOT NULL, part TEXT NOT NULL, status TEXT NOT NULL, PRIMARY KEY(event_id,provider,part))')
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



def baseline_existing_events(cfg):
    """Register existing events once, without sending notifications."""
    c = db()
    try:
        c.execute("CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT)")
        if c.execute(
            "SELECT 1 FROM settings WHERE key='baseline_complete'"
        ).fetchone():
            return

        roots = [Path(f) for f in cfg['folders']]
        if not roots or not all(root.is_dir() for root in roots):
            LOG.warning('Baseline postponed: monitoring folder unavailable')
            return

        count = 0
        for key, folder, video, meta in discover({**cfg, 'settle_seconds': 0}):
            c.execute(
                "INSERT OR IGNORE INTO events "
                "(id,path,status,attempts,error,updated) VALUES (?,?,?,?,?,?)",
                (key, str(folder), 'skipped', 0, '', int(time.time()))
            )
            count += 1

        c.execute(
            "INSERT INTO settings (key,value) VALUES (?,?)",
            ('baseline_complete', str(int(time.time())))
        )
        c.commit()
        LOG.info('Initial baseline complete: %d existing events', count)
    finally:
        c.close()


def load_translations(language='en'):
    """Load notification strings with English fallback."""
    locale_dir = Path(__file__).resolve().parent / 'locales'

    def read_locale(code):
        path = locale_dir / (code + '.json')
        data = json.loads(path.read_text(encoding='utf-8'))
        if not isinstance(data, dict):
            raise ValueError('Invalid translation format')
        return data

    try:
        english = read_locale('en')
    except (OSError, ValueError):
        LOG.exception('English translations unavailable')
        raise

    if language not in ('en', 'he') or language == 'en':
        return english

    try:
        translated = read_locale(language)
        return {
            key: translated.get(key, value)
            for key, value in english.items()
        }
    except (OSError, ValueError):
        LOG.warning('Translation unavailable: %s', language)
        return english


def event_text(folder, meta, language='en', include_map=False):
    """Build a localized WhatsApp event caption."""
    from datetime import datetime

    t = load_translations(language)

    try:
        data = json.loads(meta.read_text()) if meta.exists() else {}
    except (OSError, ValueError):
        data = {}

    lines = [t['title']]

    timestamp = data.get('timestamp')
    if timestamp:
        try:
            formatted = datetime.fromisoformat(
                str(timestamp).replace('Z', '+00:00')
            ).strftime('%d.%m.%Y | %H:%M:%S')
        except ValueError:
            formatted = str(timestamp)
        lines.append(f"{t['date_time']}: {formatted}")

    reason = data.get('reason')
    if reason:
        description = (
            t['reason_object']
            if reason == 'sentry_aware_object_detection'
            else str(reason)
        )
        lines.append(f"{t['reason']}: {description}")

    camera = data.get('camera')
    if camera is not None:
        camera_keys = {
            '0': 'camera_front',
            '5': 'camera_left',
            '6': 'camera_right',
        }
        key = camera_keys.get(str(camera))
        description = t[key] if key else str(camera)
        lines.append(f"{t['camera']}: {description}")

    location = ', '.join(
        str(data[k]) for k in ('street', 'city') if data.get(k)
    )
    if location:
        lines.append(f"{t['location']}: {location}")

    if include_map and data.get('est_lat') is not None and data.get('est_lon') is not None:
        try:
            lat = float(data['est_lat'])
            lon = float(data['est_lon'])
            if -90 <= lat <= 90 and -180 <= lon <= 180:
                lines.append(
                    f"{t['map']}:\n"
                    f"https://maps.google.com/?q={lat},{lon}"
                )
        except (TypeError, ValueError):
            pass

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


def prepare_h264_video(video):
    """Return a temporary WhatsApp-compatible H.264 video."""
    import subprocess
    import tempfile

    import shutil

    ffmpeg = shutil.which('ffmpeg') or '/mutable/tessentry/bin/ffmpeg'
    ffprobe = shutil.which('ffprobe') or '/mutable/tessentry/bin/ffprobe'

    probe = subprocess.run(
        [ffprobe, '-v', 'error', '-select_streams', 'v:0',
         '-show_entries', 'stream=codec_name,width,height,pix_fmt',
         '-of', 'json', str(video)],
        capture_output=True, text=True, check=True, timeout=30
    )
    streams = json.loads(probe.stdout).get('streams', [])
    if not streams:
        raise ValueError('No video stream found')

    stream = streams[0]
    if (stream.get('codec_name') == 'h264'
            and stream.get('pix_fmt') == 'yuv420p'
            and stream.get('width', 0) % 2 == 0
            and stream.get('height', 0) % 2 == 0):
        return video, False

    with tempfile.NamedTemporaryFile(
        prefix='tessentry-h264-', suffix='.mp4',
        dir=BASE, delete=False
    ) as tmp:
        output = Path(tmp.name)

    try:
        subprocess.run(
            [ffmpeg, '-hide_banner', '-loglevel', 'error',
             '-i', str(video), '-c:v', 'libx264',
             '-preset', 'veryfast', '-crf', '23',
             '-pix_fmt', 'yuv420p',
             '-vf', 'pad=ceil(iw/2)*2:ceil(ih/2)*2',
             '-movflags', '+faststart', '-an', '-y', str(output)],
            capture_output=True, text=True, check=True, timeout=180
        )
        if output.stat().st_size == 0:
            raise ValueError('Converted video is empty')
        return output, True
    except Exception:
        output.unlink(missing_ok=True)
        raise


def send_part(cfg,folder,video,meta,part):
    """PREVIEW adapter: API route and payload MUST be validated before enabling."""
    from urllib.parse import quote
    base=validate_openwa_url(cfg)
    session=quote(cfg['openwa_session'],safe='')
    chat=cfg['openwa_chat_id']
    headers={'X-Api-Key':cfg['openwa_api_key']}
    if part=='text':
        body=json.dumps({'chatId':chat,'text':event_text(folder,meta,cfg.get('notification_language','en'))}).encode()
        req=urllib.request.Request(f'{base}/api/sessions/{session}/messages/send-text',body,{**headers,'Content-Type':'application/json'},method='POST')
        with urllib.request.urlopen(req,timeout=30) as resp: resp.read()
    elif part=='video':
        import base64
        prepared, temporary = prepare_h264_video(video)
        try:
            body=json.dumps({
                'chatId':chat,
                'base64':base64.b64encode(prepared.read_bytes()).decode('ascii'),
                'mimetype':'video/mp4',
                'filename':'event.mp4',
                'caption':event_text(folder,meta,cfg.get('notification_language','en'))
            }).encode()
            req=urllib.request.Request(f'{base}/api/sessions/{session}/messages/send-video',body,{**headers,'Content-Type':'application/json'},method='POST')
            with urllib.request.urlopen(req,timeout=90) as resp: resp.read()
        finally:
            if temporary:
                prepared.unlink(missing_ok=True)
    else: raise ValueError('Unknown message part')


def send_location(cfg, meta):
    """Send a native WhatsApp location card when valid coordinates exist."""
    import math
    from urllib.parse import quote

    try:
        data = json.loads(meta.read_text(encoding='utf-8'))
        lat = float(data['est_lat'])
        lon = float(data['est_lon'])
    except (OSError, ValueError, TypeError, KeyError):
        return False

    if not (math.isfinite(lat) and math.isfinite(lon)
            and -90 <= lat <= 90 and -180 <= lon <= 180):
        return False

    base = validate_openwa_url(cfg)
    session = quote(cfg['openwa_session'], safe='')
    language = cfg.get('notification_language', 'en')

    description = (
        'מיקום אירוע Sentry' if language == 'he'
        else 'Sentry Event Location'
    )

    payload = {
        'chatId': cfg['openwa_chat_id'],
        'latitude': lat,
        'longitude': lon,
        'description': description,
        'address': 'Tesla Sentry'
    }

    url = f'{base}/api/sessions/{session}/messages/send-location'
    req = urllib.request.Request(
        url,
        data=json.dumps(payload).encode('utf-8'),
        headers={
            'X-Api-Key': cfg['openwa_api_key'],
            'Content-Type': 'application/json'
        },
        method='POST'
    )

    with urllib.request.urlopen(req, timeout=30) as resp:
        resp.read()

    return True



def selected_providers(cfg):
    value=cfg.get('notification_provider','whatsapp')
    if value not in ('whatsapp','telegram','both'):
        raise ValueError('Invalid notification provider')
    return ('whatsapp','telegram') if value=='both' else (value,)


def provider_configured(cfg, provider):
    keys = ('openwa_url','openwa_api_key','openwa_session','openwa_chat_id') if provider=='whatsapp' else ('telegram_bot_token','telegram_chat_id')
    return all(isinstance(cfg.get(k),str) and cfg[k].strip() for k in keys)


def telegram_request(cfg, method, fields, video=None):
    """Send a Telegram Bot API request. No third-party dependencies or token logging."""
    import re
    token=cfg.get('telegram_bot_token','').strip()
    if not re.fullmatch(r'[0-9]{5,15}:[A-Za-z0-9_-]{20,}',token):
        raise ValueError('Invalid Telegram bot token format')
    chat=cfg.get('telegram_chat_id','').strip()
    if not chat or len(chat)>128 or not re.fullmatch(r'[-@A-Za-z0-9_]+',chat):
        raise ValueError('Invalid Telegram chat ID')
    fields={'chat_id':chat,**fields}
    if video is None:
        body=json.dumps(fields,ensure_ascii=False).encode('utf-8')
        content_type='application/json'
    else:
        boundary='tessentry'+uuid.uuid4().hex
        chunks=[]
        for key,value in fields.items():
            chunks.append((f'--{boundary}\r\nContent-Disposition: form-data; name="{key}"\r\n\r\n{value}\r\n').encode())
        chunks.append((f'--{boundary}\r\nContent-Disposition: form-data; name="video"; filename="event.mp4"\r\nContent-Type: video/mp4\r\n\r\n').encode())
        chunks.append(Path(video).read_bytes())
        chunks.append(f'\r\n--{boundary}--\r\n'.encode())
        body=b''.join(chunks)
        content_type='multipart/form-data; boundary='+boundary
    # Do not expose the token-bearing URL or server response to logs or UI.
    req=urllib.request.Request('https://api.telegram.org/bot'+token+'/'+method,body,{'Content-Type':content_type},method='POST')
    try:
        with urllib.request.urlopen(req,timeout=90 if video else 30) as response:
            result=json.loads(response.read(1024*1024))
        if not result.get('ok'):
            raise RuntimeError('Telegram API rejected the request')
    except (urllib.error.HTTPError,urllib.error.URLError,TimeoutError,ValueError):
        raise RuntimeError('Telegram delivery failed; check bot credentials, destination and connectivity') from None


def telegram_location(cfg,meta):
    import math
    try:
        data=json.loads(meta.read_text(encoding='utf-8'))
        lat=float(data['est_lat']); lon=float(data['est_lon'])
    except (OSError,ValueError,TypeError,KeyError):
        return False
    if not (math.isfinite(lat) and math.isfinite(lon) and -90<=lat<=90 and -180<=lon<=180):
        return False
    telegram_request(cfg,'sendLocation',{'latitude':lat,'longitude':lon})
    return True


def telegram_event(cfg,folder,video,meta,part):
    caption=event_text(folder,meta,cfg.get('notification_language','en'))
    if part=='text':
        telegram_request(cfg,'sendMessage',{'text':caption})
    elif part=='video':
        # Telegram video captions are limited to 1024 characters.
        if len(caption)>1024:
            raise ValueError('Telegram event caption exceeds 1024 characters')
        prepared,temporary=prepare_h264_video(video)
        try:
            if prepared.stat().st_size>50*1024*1024:
                raise ValueError('Telegram video exceeds the 50 MB Bot API upload limit')
            telegram_request(cfg,'sendVideo',{'caption':caption,'supports_streaming':'true'},video=prepared)
        finally:
            if temporary: prepared.unlink(missing_ok=True)
    else: raise ValueError('Invalid Telegram event part')


def delivery_done(c,key,provider,part):
    row=c.execute('SELECT status FROM deliveries WHERE event_id=? AND provider=? AND part=?',(key,provider,part)).fetchone()
    return bool(row and row[0]=='sent')


def mark_delivery(c,key,provider,part):
    c.execute('INSERT OR REPLACE INTO deliveries(event_id,provider,part,status) VALUES (?,?,?,?)',(key,provider,part,'sent'))
    if provider=='whatsapp':
        col={'text':'text_sent','video':'video_sent','location':'location_sent'}[part]
        c.execute(f'UPDATE events SET {col}=1 WHERE id=?',(key,))
    c.commit()


def deliver_provider(c,key,cfg,provider,folder,video,meta):
    part='video' if cfg['send_video'] else 'text'
    if not (cfg['send_video'] or cfg['send_text']): return
    # Migration: retain existing WhatsApp progress for older incomplete rows.
    legacy=c.execute('SELECT text_sent,video_sent,location_sent FROM events WHERE id=?',(key,)).fetchone()
    for index,name in enumerate(('text','video','location')):
        if provider=='whatsapp' and legacy and legacy[index] and not delivery_done(c,key,provider,name):
            mark_delivery(c,key,provider,name)
    if not delivery_done(c,key,provider,part):
        if provider=='whatsapp': send_part(cfg,folder,video,meta,part)
        else: telegram_event(cfg,folder,video,meta,part)
        mark_delivery(c,key,provider,part)
    if not delivery_done(c,key,provider,'location'):
        delivered=send_location(cfg,meta) if provider=='whatsapp' else telegram_location(cfg,meta)
        # No valid location is a completed optional part.
        mark_delivery(c,key,provider,'location')

def scan_once():
    cfg=config()
    if not cfg['enabled']: return
    providers=selected_providers(cfg)
    if not all(provider_configured(cfg,p) for p in providers):
        LOG.warning('Selected notification provider is not configured')
        return
    baseline_existing_events(cfg)
    c=db()
    try:
        if not c.execute("SELECT 1 FROM settings WHERE key='baseline_complete'").fetchone():
            LOG.warning('Waiting for initial baseline')
            return
        for key,folder,video,meta in discover(cfg):
            row=c.execute('SELECT status,attempts,updated FROM events WHERE id=?',(key,)).fetchone()
            if row and row[0] in ('sent','sending','review','skipped'): continue
            if row and (row[1]>=10 or (row[2] and time.time()-row[2]<min(3600,60*2**min(row[1],6)))): continue
            attempts=(row[1] if row else 0)+1
            # Persist sending before external requests: uncertain responses require review.
            if row:
                c.execute('UPDATE events SET status=?,attempts=?,error=?,updated=? WHERE id=?',('sending',attempts,'',int(time.time()),key))
            else:
                c.execute('INSERT INTO events(id,path,status,attempts,error,updated) VALUES (?,?,?,?,?,?)',(key,str(folder),'sending',attempts,'',int(time.time())))
            c.commit()
            try:
                for provider in providers:
                    deliver_provider(c,key,cfg,provider,folder,video,meta)
                c.execute('UPDATE events SET status=?,error=?,updated=? WHERE id=?',('sent','',int(time.time()),key))
                c.commit()
                LOG.info('Sent event %s to %s',folder,','.join(providers))
            except Exception as e:
                # A timeout can mean the remote side accepted the message.
                # Never replay automatically, even if another provider succeeded.
                error=str(e)
                if cfg.get('telegram_bot_token'):
                    error=error.replace(cfg['telegram_bot_token'],'[redacted]')
                c.execute('UPDATE events SET status=?,error=?,updated=? WHERE id=?',('review',error[:300],int(time.time()),key))
                c.commit()
                LOG.error('Delivery needs review for %s: %s',folder,error)
    finally: c.close()

def worker():
    logging.basicConfig(level=logging.INFO,format='%(asctime)s %(levelname)s %(message)s')
    LOG.info('Tessentry worker started')
    while True:
        try: scan_once()
        except Exception: LOG.exception('Scan failed')
        time.sleep(max(10,min(3600,int(config()['scan_interval_seconds']))))
