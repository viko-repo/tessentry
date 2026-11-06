import json, tempfile, threading, unittest, urllib.request, urllib.parse
from pathlib import Path
from unittest.mock import patch
from http.server import ThreadingHTTPServer
from tessentry import core,web

class WebTests(unittest.TestCase):
    def test_settings_provider_choices_and_save(self):
        with tempfile.TemporaryDirectory() as d:
            base=Path(d)
            (base/'password.hash').write_text(web.hash_password('test-password'))
            with patch.object(core,'BASE',base),patch.object(web,'BASE',base):
                server=ThreadingHTTPServer(('127.0.0.1',0),web.Handler)
                thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
                url=f'http://127.0.0.1:{server.server_port}/tessentry/'
                def request(path,data=None,cookie=None):
                    headers={'Cookie':cookie} if cookie else {}
                    body=urllib.parse.urlencode(data).encode() if data is not None else None
                    with urllib.request.urlopen(urllib.request.Request(url+path,body,headers),timeout=3) as r:
                        return r.read().decode(),r.headers
                try:
                    _,headers=request('login',{'password':'test-password'})
                    cookie=headers['Set-Cookie'].split(';')[0]
                    html,_=request('settings',cookie=cookie)
                    self.assertIn('WhatsApp + Telegram',html)
                    self.assertIn('Telegram Bot Token',html)
                    token=cookie.split('=',1)[1]
                    form={'csrf':token,'notification_provider':'telegram','telegram_bot_token':'123456789:ABCDEFGHIJKLMNOPQRSTUVWXYZabcde','telegram_chat_id':'-100123456789','folders':'/mutable/TeslaCam/SentryClips','settle_seconds':'90','scan_interval_seconds':'30','send_video':'on','enabled':'on'}
                    result,_=request('settings',form,cookie)
                    self.assertIn('Settings saved',result)
                    c=core.config()
                    self.assertEqual(c['notification_provider'],'telegram')
                    self.assertTrue(c['enabled'])
                    self.assertEqual(c['telegram_chat_id'],'-100123456789')
                    html,_=request('settings',cookie=cookie)
                    self.assertNotIn('ABCDEFGHIJKLMNOPQRSTUVWXYZabcde',html)
                    self.assertIn('Configured',html)
                    result,_=request('settings',{**form,'telegram_bot_token':''},cookie)
                    self.assertIn('Settings saved',result)
                    self.assertEqual(core.config()['telegram_bot_token'],form['telegram_bot_token'])
                finally:
                    server.shutdown();server.server_close();thread.join(timeout=3)

if __name__=='__main__': unittest.main()
