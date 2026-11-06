"""End-to-end HTTP wire tests against a local Telegram Bot API emulator."""
import json
import tempfile
import threading
import unittest
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest.mock import patch
from tessentry import core

TOKEN='123456789:ABCDEFGHIJKLMNOPQRSTUVWXYZabcde'

class LocalTelegramAPI(BaseHTTPRequestHandler):
    def do_POST(self):
        size=int(self.headers['Content-Length'])
        data=self.rfile.read(size)
        self.server.received.append((self.path,self.headers.get('Content-Type'),data))
        payload=json.dumps({'ok':self.server.api_ok,'result':{'message_id':123}}).encode()
        self.send_response(200)
        self.send_header('Content-Type','application/json')
        self.send_header('Content-Length',str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)
    def log_message(self,*args): pass

class WireIntegrationTests(unittest.TestCase):
    def test_real_http_text_video_location_and_rejection(self):
        server=ThreadingHTTPServer(('127.0.0.1',0),LocalTelegramAPI)
        server.received=[]; server.api_ok=True
        thread=threading.Thread(target=server.serve_forever,daemon=True)
        thread.start()
        real_open=urllib.request.urlopen
        def local_open(req,timeout=30):
            # Keep production URL unchanged; redirect only within this isolated test.
            redirected=urllib.request.Request(
                f'http://127.0.0.1:{server.server_port}/'+req.full_url.split('/',3)[-1],
                req.data,dict(req.header_items()),method='POST')
            return real_open(redirected,timeout=timeout)
        cfg=dict(core.DEFAULTS,telegram_bot_token=TOKEN,telegram_chat_id='-100123456789')
        try:
            with tempfile.TemporaryDirectory() as tmp, patch.object(core.urllib.request,'urlopen',side_effect=local_open):
                folder=Path(tmp)
                meta=folder/'event.json'
                meta.write_text(json.dumps({'timestamp':'2026-11-06T21:00:00','camera':'0','reason':'sentry_aware_object_detection','est_lat':31.5,'est_lon':34.5}))
                video=folder/'event.mp4';video.write_bytes(b'\x00\x00\x00\x18ftypmp42MOCK_VIDEO_PAYLOAD')
                core.telegram_request(cfg,'sendMessage',{'text':'Tessentry test event'})
                with patch.object(core,'prepare_h264_video',return_value=(video,False)):
                    core.telegram_event(cfg,folder,video,meta,'video')
                self.assertTrue(core.telegram_location(cfg,meta))
                self.assertEqual(len(server.received),3)
                self.assertTrue(server.received[0][0].endswith('/sendMessage'))
                self.assertEqual(json.loads(server.received[0][2])['text'],'Tessentry test event')
                self.assertTrue(server.received[1][0].endswith('/sendVideo'))
                self.assertIn('multipart/form-data',server.received[1][1])
                self.assertIn(b'MOCK_VIDEO_PAYLOAD',server.received[1][2])
                self.assertTrue(server.received[2][0].endswith('/sendLocation'))
                self.assertEqual(json.loads(server.received[2][2])['latitude'],31.5)
                server.api_ok=False
                with self.assertRaisesRegex(RuntimeError,'Telegram API rejected'):
                    core.telegram_request(cfg,'sendMessage',{'text':'test rejection'})
        finally:
            server.shutdown();server.server_close();thread.join(timeout=3)

if __name__=='__main__': unittest.main()
