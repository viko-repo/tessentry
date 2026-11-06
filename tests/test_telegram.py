import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
from tessentry import core

TOKEN='123456789:ABCDEFGHIJKLMNOPQRSTUVWXYZabcde'

class TelegramTests(unittest.TestCase):
    def cfg(self, **kwargs):
        return dict(core.DEFAULTS,notification_provider='telegram',telegram_bot_token=TOKEN,telegram_chat_id='-100123456789',**kwargs)

    def test_provider_defaults_and_selection(self):
        self.assertEqual(core.selected_providers(core.DEFAULTS),('whatsapp',))
        self.assertEqual(core.selected_providers(dict(core.DEFAULTS,notification_provider='both')),('whatsapp','telegram'))
        with self.assertRaises(ValueError): core.selected_providers(dict(core.DEFAULTS,notification_provider='invalid'))

    def test_telegram_json_request(self):
        class Response:
            def __enter__(self): return self
            def __exit__(self,*args): pass
            def read(self,n): return b'{"ok":true,"result":{}}'
        with patch.object(core.urllib.request,'urlopen',return_value=Response()) as call:
            core.telegram_request(self.cfg(),'sendMessage',{'text':'Hello'})
            req=call.call_args.args[0]
            self.assertIn('/sendMessage',req.full_url)
            self.assertEqual(json.loads(req.data)['chat_id'],'-100123456789')
            self.assertEqual(json.loads(req.data)['text'],'Hello')

    def test_video_multipart(self):
        class Response:
            def __enter__(self): return self
            def __exit__(self,*args): pass
            def read(self,n): return b'{"ok":true}'
        with tempfile.TemporaryDirectory() as d:
            video=Path(d)/'event.mp4';video.write_bytes(b'fakevideo123')
            with patch.object(core.urllib.request,'urlopen',return_value=Response()) as call:
                core.telegram_request(self.cfg(),'sendVideo',{'caption':'Event'},video)
                req=call.call_args.args[0]
                self.assertIn('multipart/form-data',req.get_header('Content-type'))
                self.assertIn(b'fakevideo123',req.data)
                self.assertIn(b'event.mp4',req.data)

    def test_location(self):
        with tempfile.TemporaryDirectory() as d:
            f=Path(d)/'event.json';f.write_text(json.dumps({'est_lat':31.5,'est_lon':34.5}))
            with patch.object(core,'telegram_request') as req:
                self.assertTrue(core.telegram_location(self.cfg(),f))
                self.assertEqual(req.call_args.args[1],'sendLocation')
                self.assertEqual(req.call_args.args[2]['latitude'],31.5)
            f.write_text(json.dumps({'est_lat':999,'est_lon':34.5}))
            with patch.object(core,'telegram_request') as req:
                self.assertFalse(core.telegram_location(self.cfg(),f))
                req.assert_not_called()

    def test_dual_delivery_progress_and_no_duplicate(self):
        with tempfile.TemporaryDirectory() as d:
            with patch.object(core,'BASE',Path(d)):
                c=core.db()
                key='event-1'
                c.execute('INSERT INTO events(id,path,status,attempts,error,updated) VALUES (?,?,?,?,?,?)',(key,'/event','sending',1,'',0));c.commit()
                cfg=dict(self.cfg(),notification_provider='both',openwa_url='http://100.75.224.110:2785',openwa_api_key='test',openwa_session='default',openwa_chat_id='test')
                with patch.object(core,'send_part') as wa,patch.object(core,'send_location',return_value=True),patch.object(core,'telegram_event',side_effect=[RuntimeError('temporary'),None]) as tg,patch.object(core,'telegram_location',return_value=True):
                    core.deliver_provider(c,key,cfg,'whatsapp',Path(d),Path(d)/'event.mp4',Path(d)/'event.json')
                    with self.assertRaises(RuntimeError):
                        core.deliver_provider(c,key,cfg,'telegram',Path(d),Path(d)/'event.mp4',Path(d)/'event.json')
                    core.deliver_provider(c,key,cfg,'whatsapp',Path(d),Path(d)/'event.mp4',Path(d)/'event.json')
                    core.deliver_provider(c,key,cfg,'telegram',Path(d),Path(d)/'event.mp4',Path(d)/'event.json')
                    self.assertEqual(wa.call_count,1)
                    self.assertEqual(tg.call_count,2)
                    self.assertTrue(core.delivery_done(c,key,'whatsapp','video'))
                    self.assertTrue(core.delivery_done(c,key,'telegram','video'))
                c.close()

    def test_legacy_config_unchanged(self):
        with tempfile.TemporaryDirectory() as d:
            with patch.object(core,'BASE',Path(d)):
                (Path(d)/'config.json').write_text(json.dumps({'enabled':True,'openwa_url':'http://100.75.224.110:2785'}))
                cfg=core.config()
                self.assertEqual(cfg['notification_provider'],'whatsapp')
                self.assertTrue(cfg['enabled'])

if __name__=='__main__': unittest.main()
