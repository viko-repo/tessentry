"""Small password-protected management UI, no external Python dependencies."""
import os,json,html,secrets,hashlib,hmac,threading,time,logging,socket,subprocess
from pathlib import Path
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
from urllib.parse import parse_qs,urlparse
from .core import BASE,config,save_config,status,db,validate_openwa_url
SESS={}; LOCK=threading.Lock()

def hash_password(p,salt=None):
    salt=salt or secrets.token_bytes(16)
    return salt.hex()+':'+hashlib.scrypt(p.encode(),salt=salt,n=16384,r=8,p=1).hex()

def verify(p,stored):
    try:
        salt,actual=stored.split(':'); return hmac.compare_digest(hash_password(p,bytes.fromhex(salt)),stored)
    except Exception:return False

def esc(v):return html.escape(str(v),quote=True)

def page(title,body):
    return f"""<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>{esc(title)} · Tessentry</title><style>body{{font:16px system-ui;background:#10151c;color:#eef2f7;max-width:760px;margin:35px auto;padding:0 16px}}main{{background:#1b2530;padding:25px;border-radius:16px}}input,textarea{{box-sizing:border-box;width:100%;background:#0e1720;color:white;border:1px solid #526173;border-radius:7px;padding:10px;margin:5px 0 16px}}input[type=checkbox]{{width:auto}}button{{padding:11px 18px;border:0;border-radius:8px;background:#5fa9f8;color:#07101a;cursor:pointer}}a{{color:#9bcaff}}label{{display:block}}small{{color:#abb9c9}}nav a{{margin-right:18px}}pre{{white-space:pre-wrap;overflow-wrap:anywhere}}</style><main><h1>🚗 Tessentry</h1><nav><a href="/tessentry/">Status</a><a href="/tessentry/settings">Settings</a><a href="/tessentry/logout">Log out</a></nav><hr>{body}</main></html>"""

class Handler(BaseHTTPRequestHandler):
    def send(self,body,code=200,cookie=None):
        b=body.encode();self.send_response(code);self.send_header('Content-Type','text/html; charset=utf-8');self.send_header('Content-Length',str(len(b)));self.send_header('Cache-Control','no-store');self.send_header('X-Content-Type-Options','nosniff');self.send_header('X-Frame-Options','DENY');self.send_header('Content-Security-Policy',"default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; base-uri 'none'")
        if cookie:self.send_header('Set-Cookie',cookie)
        self.end_headers();self.wfile.write(b)
    def fields(self):
        size=int(self.headers.get('Content-Length','0'))
        if size>16384:raise ValueError('Request too large')
        return {k:v[0] for k,v in parse_qs(self.rfile.read(size).decode(),keep_blank_values=True).items()}
    def session(self):
        token=''
        for part in self.headers.get('Cookie','').split(';'):
            if part.strip().startswith('tsid='):token=part.strip()[5:]
        with LOCK:
            entry=SESS.get(token)
            if entry and entry[1]>time.time():return entry[0]
        return None
    def do_GET(self):
        path=urlparse(self.path).path
        if path=='/tessentry/logout':
            with LOCK: SESS.clear()
            return self.send(page('Logout','<p>Logged out.</p>'),cookie='tsid=; Path=/tessentry; Max-Age=0; HttpOnly; SameSite=Strict')
        if not self.session():return self.send(page('Login','<h2>Sign in</h2><form method="post" action="/tessentry/login"><label>Password<input type="password" name="password" required></label><button>Sign in</button></form>'),401)
        if path=='/tessentry/settings':
            c=config();token=self.session();s='<h2>Settings</h2><p><small>Secrets are stored locally, never committed to GitHub. Saving does not send test messages.</small></p><form method="post" action="/tessentry/settings"><input type="hidden" name="csrf" value="'+esc(token)+'">'
            for k,label in [('openwa_url','OpenWA base URL (e.g. http://100.75.224.110:2785)'),('openwa_session','OpenWA session'),('openwa_chat_id','WhatsApp chat/group ID')]:s+=f'<label>{label}<input name="{k}" value="{esc(c[k])}"></label>'
            s+='<label>OpenWA API key (leave blank to keep current)<input type="password" name="openwa_api_key" autocomplete="new-password" placeholder="'+('Configured' if c['openwa_api_key'] else 'Not configured')+'"></label>'
            s+='<label>Event folders (one per line)<textarea name="folders" rows="3">'+esc('\n'.join(c['folders']))+'</textarea></label>'
            s+='<label>Notification language<select name="notification_language">'
            for code,label in [('en','English'),('he','עברית (Hebrew)')]:
                selected=' selected' if c['notification_language']==code else ''
                s+=f'<option value="{code}"{selected}>{label}</option>'
            s+='</select></label>'
            for k,label in [('enabled','Enable monitoring'),('send_text','Send event details'),('send_video','Send event.mp4'),('allow_non_tailnet','Allow OpenWA URL outside Tailscale (LAN only)')]:s+=f'<label><input type="checkbox" name="{k}" {"checked" if c[k] else ""}> {label}</label>'
            for k,label in [('settle_seconds','Minimum file age in seconds'),('scan_interval_seconds','Scan interval in seconds')]:s+=f'<label>{label}<input type="number" name="{k}" value="{esc(c[k])}" min="10" max="3600"></label>'
            s+='<button>Save settings</button></form><p><small>OpenWA message API routes and payloads must be verified on your server before enabling monitoring.</small></p>'
            return self.send(page('Settings',s))
        if path=='/tessentry/':
            st=status(); c=config(); conn=db(); rows=conn.execute('SELECT path,status,attempts,error,updated FROM events ORDER BY updated DESC LIMIT 20').fetchall();conn.close()
            s='<h2>Status</h2><p>Monitoring: <b>'+('enabled' if c['enabled'] else 'disabled')+'</b></p><p>OpenWA configured: '+('yes' if all(c.get(k) for k in ('openwa_url','openwa_api_key','openwa_session','openwa_chat_id')) else 'no')+'</p><p>Events: '+esc(st['counts'])+'</p><h3>Watched folders</h3>'
            for x in st['folders']:s+='<p>'+esc(x['path'])+' — '+('available' if x['exists'] else 'missing')+'</p>'
            # Local health probes only; never send API keys to a status endpoint.
            try:
                ts=subprocess.run(['/usr/bin/tailscale','ip','-4'],capture_output=True,text=True,timeout=3)
                tailnet='available' if ts.returncode==0 and ts.stdout.strip() else 'unavailable'
            except (OSError,subprocess.TimeoutExpired): tailnet='unavailable'
            s+='<p>Tailscale: '+tailnet+'</p>'
            try:
                from urllib.parse import urlsplit
                validate_openwa_url(c)
                target=urlsplit(c['openwa_url']); port=target.port or (443 if target.scheme=='https' else 80)
                with socket.create_connection((target.hostname,port),timeout=2): pass
                openwa='TCP reachable (API not verified)'
            except Exception: openwa='unreachable or not configured'
            s+='<p>OpenWA: '+esc(openwa)+'</p>'
            s+='<p>Worker: check systemctl tessentry-worker (web process cannot attest to worker health)</p>'
            s+='<h3>Recent events</h3>'
            for r in rows:s+='<p>'+esc(r[1])+' · '+esc(r[0])+' · attempts '+esc(r[2])+' '+esc(r[3])+'</p>'
            s+='<p><small>Events in review require manual inspection; no automatic retry.</small></p>'
            return self.send(page('Status',s))
        self.send(page('Not found','Not found'),404)
    def do_POST(self):
        try:f=self.fields()
        except Exception:return self.send(page('Error','Invalid request'),400)
        path=urlparse(self.path).path
        if path=='/tessentry/login':
            try:stored=(BASE/'password.hash').read_text().strip()
            except OSError:return self.send(page('Setup','Password not initialized'),503)
            if not verify(f.get('password',''),stored):return self.send(page('Login','Invalid password'),403)
            token=secrets.token_urlsafe(32)
            with LOCK:SESS[token]=(token,time.time()+8*3600)
            return self.send(page('Welcome','<p>Signed in. <a href="/tessentry/">Open status</a></p>'),cookie='tsid='+token+'; Path=/tessentry; HttpOnly; SameSite=Strict')
        token=self.session()
        if not token or not hmac.compare_digest(f.get('csrf',''),token):return self.send(page('Forbidden','Invalid session'),403)
        if path!='/tessentry/settings':return self.send(page('Not found','Not found'),404)
        c=config()
        for k in ('openwa_url','openwa_session','openwa_chat_id'):c[k]=f.get(k,'').strip()
        if f.get('openwa_api_key','').strip():c['openwa_api_key']=f['openwa_api_key'].strip()
        folders=[x.strip() for x in f.get('folders','').splitlines() if x.strip()]
        if not folders or len(folders)>10 or any(not x.startswith('/mutable/TeslaCam/') and not x.startswith('/var/www/html/TeslaCam/') for x in folders):return self.send(page('Invalid folders','Use absolute TeslaCam paths only.'),400)
        c['folders']=folders
        language=f.get('notification_language','en')
        if language not in ('en','he'):
            return self.send(page('Invalid','Unsupported notification language.'),400)
        c['notification_language']=language
        for k in ('enabled','send_text','send_video','allow_non_tailnet'):c[k]=k in f
        try:
            for k in ('settle_seconds','scan_interval_seconds'):
                v=int(f.get(k,'30'))
                if not 10<=v<=3600:raise ValueError()
                c[k]=v
        except ValueError:return self.send(page('Invalid','Intervals must be 10–3600 seconds.'),400)
        save_config(c)
        return self.send(page('Saved','<p>Settings saved. <a href="/tessentry/">Back to status</a></p>'))

def main():
    logging.basicConfig(level=logging.INFO)
    host=os.environ.get('TESSENTRY_BIND','127.0.0.1');port=int(os.environ.get('TESSENTRY_PORT','8788'))
    ThreadingHTTPServer((host,port),Handler).serve_forever()
